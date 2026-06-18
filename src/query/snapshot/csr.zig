//! Detached CSR materialization of a captured snapshot view.
//!
//! `materializeForwardCsr` copies the snapshot's logical forward adjacency
//! into caller-owned flat arrays (offsets + targets, classic CSR). The result
//! is fully independent of the graph: it holds no reader guard, pins no
//! epoch, and stays valid after the originating `ReadSnapshot` (and even the
//! `Graph`) is deinitialized. This is the intended bridge to external
//! analytics engines (DuckDB, Arrow, NumPy-style tooling) and the
//! bounded-memory option for long-lived read views: a zero-copy
//! `ReadSnapshot` blocks retired-storage reclamation for as long as it
//! lives, a `CsrView` does not.

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_validity = @import("../../core/node_validity.zig");
const page_ops = @import("../../storage/page_ops.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const types = @import("../../core/types.zig");
const snapshot_iterators = @import("iterators.zig");
const snapshot_view = @import("view.zig");

/// Caller-owned forward CSR. `out_offsets` has `node_count + 1` entries;
/// node `i`'s neighbors are `out_targets[out_offsets[i]..out_offsets[i+1]]`,
/// already filtered to live destinations within the snapshot frontier.
/// Removed nodes keep an empty range; `isLive` distinguishes them from
/// live zero-degree nodes.
pub const CsrView = struct {
    node_count: u32,
    out_offsets: []u64,
    out_targets: []u32,
    alive_node_bitmap: []u64,
    /// Stable property rows aligned with `out_targets` (edge_properties
    /// mode); null when the graph has no property rows.
    out_rows: ?[]u32 = null,

    pub fn deinit(self: *CsrView, allocator: std.mem.Allocator) void {
        allocator.free(self.out_offsets);
        allocator.free(self.out_targets);
        allocator.free(self.alive_node_bitmap);
        if (self.out_rows) |rows| allocator.free(rows);
        self.* = undefined;
    }

    pub fn nodeCount(self: *const CsrView) usize {
        return self.node_count;
    }

    pub fn edgeCount(self: *const CsrView) u64 {
        return self.out_offsets[self.node_count];
    }

    pub fn isLive(self: *const CsrView, node: types.NodeId) bool {
        if (node.index >= self.node_count) return false;
        const word = self.alive_node_bitmap[node.index / 64];
        return (word >> @as(u6, @intCast(node.index % 64))) & 1 != 0;
    }

    pub fn outDegree(self: *const CsrView, node: types.NodeId) types.GraphError!usize {
        if (!self.isLive(node)) return error.InvalidNode;
        return @intCast(self.out_offsets[node.index + 1] - self.out_offsets[node.index]);
    }

    /// Raw destination indices, sorted within each source block at capture
    /// time. Returns an empty slice for removed nodes.
    pub fn outNeighbors(self: *const CsrView, node: types.NodeId) types.GraphError![]const u32 {
        if (!self.isLive(node)) return error.InvalidNode;
        const start: usize = @intCast(self.out_offsets[node.index]);
        const end: usize = @intCast(self.out_offsets[node.index + 1]);
        return self.out_targets[start..end];
    }
};

pub fn materializeForwardCsr(view: *const snapshot_view.CapturedGraphView, allocator: std.mem.Allocator) types.GraphError!CsrView {
    const node_count = view.nodeCount();

    const out_offsets = try allocator.alloc(u64, node_count + 1);
    errdefer allocator.free(out_offsets);
    const alive_node_bitmap = try allocator.alloc(u64, (node_count + 63) / 64);
    errdefer allocator.free(alive_node_bitmap);
    @memset(alive_node_bitmap, 0);

    var degree_total: u64 = 0;
    for (view.degree_fwd) |degree| degree_total += degree;

    var out_targets: std.ArrayList(u32) = .empty;
    errdefer out_targets.deinit(allocator);
    try out_targets.ensureTotalCapacity(allocator, @intCast(degree_total));

    const with_rows = view.core.edge_properties_enabled;
    var out_rows: std.ArrayList(u32) = .empty;
    errdefer out_rows.deinit(allocator);
    if (with_rows) try out_rows.ensureTotalCapacity(allocator, @intCast(degree_total));

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        out_offsets[node_idx_usize] = out_targets.items.len;
        if (!view.isLiveIndex(node_idx)) continue;
        alive_node_bitmap[node_idx_usize / 64] |= @as(u64, 1) << @as(u6, @intCast(node_idx_usize % 64));

        if (with_rows) {
            // Edge-aware walk keeps property rows aligned with targets.
            var cursor = (try snapshot_iterators.outEdges(view, .{ .index = node_idx })) orelse continue;
            while (cursor.next()) |edge| {
                try out_targets.append(allocator, edge.destination);
                try out_rows.append(allocator, edge.property_row);
            }
        } else {
            var cursor = (try snapshot_iterators.neighborsCursor(view, .{ .index = node_idx })) orelse continue;
            while (cursor.next()) |neighbor| {
                try out_targets.append(allocator, neighbor.index);
            }
        }
    }
    out_offsets[node_count] = out_targets.items.len;

    return .{
        .node_count = @intCast(node_count),
        .out_offsets = out_offsets,
        .out_targets = try out_targets.toOwnedSlice(allocator),
        .alive_node_bitmap = alive_node_bitmap,
        .out_rows = if (with_rows) try out_rows.toOwnedSlice(allocator) else null,
    };
}

const DirectRowSink = struct {
    out_targets: *std.ArrayList(u32),
    out_rows: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    len_bound: u32,
    check_removed: bool,
    core: *const graph_core.GraphCore,

    fn onEntry(self: *DirectRowSink, entry: side_ops.ForwardEntryView) !void {
        if (entry.destination >= self.len_bound) return;
        if (self.check_removed and node_validity.isNodeRemovedIndex(self.core, entry.destination)) return;
        try self.out_targets.append(self.allocator, entry.destination);
        try self.out_rows.append(self.allocator, entry.prop_row);
    }
};

/// Builds a `CsrView` directly from the live published state under one
/// reader guard, without materializing the intermediate SoA snapshot view —
/// the cheap path for full-graph analytics export. Same logical contract as
/// snapshot-then-materialize: per-node coherent (seqlock per node), logical
/// forward adjacency with tombstones filtered, frontier fixed at entry.
/// Never-published nodes (all-zero publication state) contribute an empty row at the cost
/// of a single atomic load, so sparse graphs export in O(touched storage).
pub fn materializeForwardCsrLive(core: *const graph_core.GraphCore, allocator: std.mem.Allocator) types.GraphError!CsrView {
    const node_count: usize = core.publishedNodeCount();

    const out_offsets = try allocator.alloc(u64, node_count + 1);
    errdefer allocator.free(out_offsets);
    const alive_node_bitmap = try allocator.alloc(u64, (node_count + 63) / 64);
    errdefer allocator.free(alive_node_bitmap);
    @memset(alive_node_bitmap, 0);

    var out_targets: std.ArrayList(u32) = .empty;
    errdefer out_targets.deinit(allocator);
    try out_targets.ensureTotalCapacity(allocator, @intCast(core.edge_count.load(.acquire)));

    const with_rows = core.edge_properties_enabled;
    var out_rows: std.ArrayList(u32) = .empty;
    errdefer out_rows.deinit(allocator);
    if (with_rows) try out_rows.ensureTotalCapacity(allocator, out_targets.capacity);

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        out_offsets[node_idx_usize] = out_targets.items.len;

        const node = types.NodeId{ .index = node_idx };
        const publication_cell = page_ops.nodePublicationAtConst(core, node);
        var state = publication_cell.loadPublicationState();
        // Logical fast path: an all-zero publication state word means no publish ever
        // committed — live node, empty logical adjacency.
        if (@as(u64, @bitCast(state)) == 0) {
            alive_node_bitmap[node_idx_usize / 64] |= @as(u64, 1) << @as(u6, @intCast(node_idx_usize % 64));
            continue;
        }

        // Seqlock compose — same reader rule as live_read_common.captureNodeSnapshot.
        var side: types.SideAdj = undefined;
        var removed: bool = undefined;
        var check_removed: bool = undefined;
        while (true) {
            side = node_access.publishedFwdFromState(core, node, state);
            removed = state.removed;
            check_removed = state.needs_repair_fwd;
            const after = publication_cell.loadPublicationState();
            if (@as(u64, @bitCast(state)) == @as(u64, @bitCast(after))) break;
            state = after;
        }
        if (removed) continue;
        alive_node_bitmap[node_idx_usize / 64] |= @as(u64, 1) << @as(u6, @intCast(node_idx_usize % 64));
        if (side.block_count == 0) continue;

        var sink = DirectRowSink{
            .out_targets = &out_targets,
            .out_rows = &out_rows,
            .allocator = allocator,
            .len_bound = @intCast(node_count),
            .check_removed = check_removed,
            .core = core,
        };
        if (with_rows) {
            try side_ops.forEachForwardEntryInSide(core, side, &sink, struct {
                fn segment(_: *const graph_core.GraphCore, inner_sink: *DirectRowSink, entry: side_ops.ForwardEntryView) !void {
                    try inner_sink.onEntry(entry);
                }
            }.segment);
        } else {
            try side_ops.forEachNodeIdInSide(core, side, .fwd, &sink, struct {
                fn segment(inner_core: *const graph_core.GraphCore, inner_sink: *DirectRowSink, candidate: u32) !void {
                    if (candidate >= inner_sink.len_bound) return;
                    if (inner_sink.check_removed and node_validity.isNodeRemovedIndex(inner_core, candidate)) return;
                    try inner_sink.out_targets.append(inner_sink.allocator, candidate);
                }
            }.segment);
        }
    }
    out_offsets[node_count] = out_targets.items.len;

    return .{
        .node_count = @intCast(node_count),
        .out_offsets = out_offsets,
        .out_targets = try out_targets.toOwnedSlice(allocator),
        .alive_node_bitmap = alive_node_bitmap,
        .out_rows = if (with_rows) try out_rows.toOwnedSlice(allocator) else null,
    };
}
