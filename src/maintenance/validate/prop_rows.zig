//! Property-row validation (edge_properties mode), mirroring the multigraph
//! edge-id checks: every live forward entry must carry a non-zero row below
//! the allocation counter, and no row may be owned by two live entries.
//!
//! The fast path checks range only (allocation-free, per entry). The debug
//! path additionally audits global uniqueness with an allocating row → owner
//! map — rows are graph-global, so uniqueness cannot be verified per node.

const std = @import("std");
const common = @import("common.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_validity = @import("../../core/node_validity.zig");
const types = @import("../../core/types.zig");

const RangeScan = struct {
    node_id: u32,
    row_limit: u32,
    allocator: ?std.mem.Allocator = null,
    violations: ?*std.ArrayList(types.Violation) = null,
    fail_fast: bool = false,
};

fn appendInvalidRow(scan: *RangeScan, block_idx: u32, slot: usize, row: u32) !void {
    if (scan.fail_fast) return error.CorruptGraph;
    try scan.violations.?.append(scan.allocator.?, .{ .invalid_prop_row = .{
        .node = scan.node_id,
        .block = block_idx,
        .slot = @intCast(slot),
        .row = row,
    } });
}

fn scanForwardPropRowRanges(
    graph: *const graph_core.GraphCore,
    node_id: u32,
    adjacency: types.NodeAdj,
    allocator: ?std.mem.Allocator,
    violations: ?*std.ArrayList(types.Violation),
    fail_fast: bool,
) !void {
    if (!graph.edge_properties_enabled) return;
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;

    var scan = RangeScan{
        .node_id = node_id,
        .row_limit = graph.loadPropRowCount(),
        .allocator = allocator,
        .violations = violations,
        .fail_fast = fail_fast,
    };

    try common.forEachForwardEntryInAdj(graph, adjacency, &scan, struct {
        fn callback(_: *const graph_core.GraphCore, inner_scan: *RangeScan, entry: common.ForwardEntryView) !void {
            if (entry.prop_row == 0 or entry.prop_row >= inner_scan.row_limit) {
                try appendInvalidRow(inner_scan, entry.block_idx, entry.slot, entry.prop_row);
            }
        }
    }.callback);
}

/// Fast path: range-only, allocation-free. Wired into `validate()`.
pub fn validateForwardPropRowsFast(
    graph: *const graph_core.GraphCore,
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardPropRowRanges(graph, node_id, adjacency, null, null, true);
}

/// Debug path per node: range violations appended to the list.
pub fn appendForwardPropRowViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardPropRowRanges(graph, node_id, adjacency, allocator, violations, false);
}

const UniquenessScan = struct {
    node_id: u32,
    seen: *std.AutoHashMap(u32, u32),
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
};

/// Debug-only global pass: every live forward row must be owned by exactly
/// one live entry across the whole graph.
pub fn appendGlobalPropRowUniquenessViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
) !void {
    if (!graph.edge_properties_enabled) return;

    var seen = std.AutoHashMap(u32, u32).init(allocator);
    defer seen.deinit();

    const node_count = graph.publishedNodeCount();
    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const node = types.NodeId{ .index = node_id };
        if (node_validity.isNodeRemovedIndex(graph, node_id)) continue;
        const adjacency = node_access.publishedAdjAtConst(graph, node);
        if (common.blockCount(adjacency, .fwd) == 0) continue;

        var scan = UniquenessScan{
            .node_id = node_id,
            .seen = &seen,
            .allocator = allocator,
            .violations = violations,
        };
        try common.forEachForwardEntryInAdj(graph, adjacency, &scan, struct {
            fn callback(_: *const graph_core.GraphCore, inner_scan: *UniquenessScan, entry: common.ForwardEntryView) !void {
                if (entry.prop_row == 0) return; // range pass reports it
                const slot = try inner_scan.seen.getOrPut(entry.prop_row);
                if (slot.found_existing) {
                    try inner_scan.violations.append(inner_scan.allocator, .{ .duplicate_prop_row = .{
                        .node_a = slot.value_ptr.*,
                        .node_b = inner_scan.node_id,
                        .row = entry.prop_row,
                    } });
                    return;
                }
                slot.value_ptr.* = inner_scan.node_id;
            }
        }.callback);
    }
}
