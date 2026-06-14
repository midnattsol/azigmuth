//! Wayfind plan executor.
//!
//! Runs a validated plan against one `CapturedGraphView` — a stack machine
//! over NodeSets (flat u64 bitmaps sized to the view's node count, plus a
//! tracked cardinality).
//!
//! Cost model contract: every step is one pass over its operand sets;
//! `expand{m..n}` is at most n level-synchronous frontier sweeps with a
//! visited bitmap (each node expands at most once). Nothing here may
//! introduce hidden quadratic work — predictable cost is the language's
//! reason to exist. The one documented exception: `in`-expansion with a
//! specific relation must confirm each candidate against the forward side
//! of its source (reverse blocks store sources only, not relations), which
//! costs one forward-adjacency scan per candidate.

const std = @import("std");
const ir = @import("ir.zig");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const snapshot_view = @import("../snapshot/view.zig");
const snapshot_capture = @import("../snapshot/capture.zig");
const snapshot_csr = @import("../snapshot/csr.zig");
const node_published = @import("../../storage/node/published.zig");
const page_ops = @import("../../storage/page_ops.zig");
const context_mod = @import("../../algorithms/context.zig");

/// Caller-provided parameter sets, indexed by plan slot. Bind semantics,
/// normative: duplicates are deduplicated; ids of REMOVED nodes are
/// silently dropped (stale sets from older snapshots stay usable);
/// out-of-range ids (>= nodeCount) are an `InvalidNode` error — they were
/// never valid, so they signal a bug, not staleness.
pub const Params = struct {
    sets: []const []const u32 = &.{},
};

pub const Result = union(enum) {
    /// Sorted ascending, no duplicates (normative).
    ids: []u32,
    count: u64,
    exists: bool,
    /// Sorted by (source, destination, prop_row); both endpoints in-set.
    edges: []ir.EdgeRow,
    /// Induced subgraph: offsets span ALL node ids (non-members empty),
    /// targets are members only, alive_node_bitmap is the membership bitmap.
    csr: snapshot_csr.CsrView,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ids => |payload| allocator.free(payload),
            .edges => |payload| allocator.free(payload),
            .csr => |*view| view.deinit(allocator),
            .count, .exists => {},
        }
        self.* = undefined;
    }
};

pub const ExecError = ir.PlanError || types.GraphError || error{
    /// params.sets.len != plan.param_count.
    ParamCountMismatch,
    /// A parameter set or seed contains a node id >= view.nodeCount(),
    /// or a seed_node references a removed node.
    InvalidNode,
};

/// Executes `plan` against `view`. Every plan is validated first — the
/// comptime builder cannot produce an invalid one, but validation is cheap
/// relative to any traversal and `run` accepts runtime plans too.
pub fn run(
    plan: ir.Plan,
    view: *const snapshot_view.CapturedGraphView,
    ctx: context_mod.Context,
    params: Params,
) ExecError!Result {
    try ir.validate(plan);
    if (params.sets.len != plan.param_count) return error.ParamCountMismatch;

    const allocator = ctx.allocator;
    const node_count: u32 = @intCast(view.nodeCount());
    const word_len = wordsFor(node_count);

    // Bind every parameter up front so InvalidNode surfaces deterministically.
    var bound = try allocator.alloc(NodeSet, params.sets.len);
    var bound_ready: usize = 0;
    defer {
        for (bound[0..bound_ready]) |*set| set.destroy(allocator);
        allocator.free(bound);
    }
    for (params.sets, 0..) |ids, slot| {
        var set = try NodeSet.create(allocator, word_len);
        errdefer set.destroy(allocator);
        for (ids) |id| {
            if (id >= node_count) return error.InvalidNode;
            if (!view.isLiveIndex(id)) continue;
            _ = set.insert(id);
        }
        bound[slot] = set;
        bound_ready += 1;
    }

    var stack: std.ArrayList(NodeSet) = .empty;
    defer {
        for (stack.items) |*set| set.destroy(allocator);
        stack.deinit(allocator);
    }
    // One slot per step over-reserves, so pushes below cannot fail.
    try stack.ensureTotalCapacity(allocator, plan.steps.len);

    for (plan.steps) |step| {
        switch (step.op) {
            .seed_param => stack.appendAssumeCapacity(try bound[step.param].dupe(allocator)),
            .seed_node => {
                if (step.arg >= node_count or !view.isLiveIndex(step.arg)) return error.InvalidNode;
                var set = try NodeSet.create(allocator, word_len);
                _ = set.insert(step.arg);
                stack.appendAssumeCapacity(set);
            },
            .all_nodes => {
                var set = try NodeSet.create(allocator, word_len);
                errdefer set.destroy(allocator);
                for (0..node_count) |idx| {
                    const node_idx: u32 = @intCast(idx);
                    if (view.isLiveIndex(node_idx)) _ = set.insert(node_idx);
                }
                stack.appendAssumeCapacity(set);
            },
            .expand => {
                var input = stack.pop().?;
                defer input.destroy(allocator);
                stack.appendAssumeCapacity(try execExpand(view, allocator, &input, step));
            },
            .set_union, .set_intersect, .set_minus => {
                var top = stack.pop().?;
                defer top.destroy(allocator);
                execSetOp(step.op, &stack.items[stack.items.len - 1], &top);
            },
            .filter_degree => execFilterDegree(view, &stack.items[stack.items.len - 1], step),
            .emit_ids => {
                var final = stack.pop().?;
                defer final.destroy(allocator);
                return .{ .ids = try emitIds(allocator, &final) };
            },
            .emit_count => {
                var final = stack.pop().?;
                const cardinality = final.count;
                final.destroy(allocator);
                return .{ .count = cardinality };
            },
            .emit_exists => {
                var final = stack.pop().?;
                const non_empty = final.count != 0;
                final.destroy(allocator);
                return .{ .exists = non_empty };
            },
            .emit_edges => {
                var final = stack.pop().?;
                defer final.destroy(allocator);
                return .{ .edges = try emitEdges(view, allocator, &final) };
            },
            .emit_csr => {
                var final = stack.pop().?;
                defer final.destroy(allocator);
                return .{ .csr = try emitCsr(view, allocator, &final) };
            },
        }
    }
    unreachable; // validate guarantees a terminal as the last step
}

// ── NodeSet ──────────────────────────────────────────────────────────────

/// Flat bitmap over node ids plus a tracked cardinality. Sized once per
/// run (the view's node count is fixed), so all sets of a run share one
/// word length and set ops are straight word loops.
pub const NodeSet = struct {
    words: []u64,
    count: u32,

    fn create(allocator: std.mem.Allocator, word_len: usize) !NodeSet {
        const words = try allocator.alloc(u64, word_len);
        @memset(words, 0);
        return .{ .words = words, .count = 0 };
    }

    fn destroy(self: *NodeSet, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        self.* = undefined;
    }

    fn dupe(self: *const NodeSet, allocator: std.mem.Allocator) !NodeSet {
        return .{ .words = try allocator.dupe(u64, self.words), .count = self.count };
    }

    inline fn contains(self: *const NodeSet, node_idx: u32) bool {
        return (self.words[node_idx / 64] >> @as(u6, @intCast(node_idx % 64))) & 1 != 0;
    }

    /// Returns true when the bit was newly set.
    inline fn insert(self: *NodeSet, node_idx: u32) bool {
        const mask = @as(u64, 1) << @as(u6, @intCast(node_idx % 64));
        const word = &self.words[node_idx / 64];
        if (word.* & mask != 0) return false;
        word.* |= mask;
        self.count += 1;
        return true;
    }

    const Iterator = struct {
        words: []const u64,
        word_idx: usize = 0,
        current: u64 = 0,

        fn next(self: *Iterator) ?u32 {
            while (self.current == 0) {
                if (self.word_idx >= self.words.len) return null;
                self.current = self.words[self.word_idx];
                self.word_idx += 1;
            }
            const bit: u32 = @intCast(@ctz(self.current));
            self.current &= self.current - 1;
            return @intCast((self.word_idx - 1) * 64 + bit);
        }
    };

    /// Ascending member iteration.
    fn iterator(self: *const NodeSet) Iterator {
        return .{ .words = self.words };
    }
};

fn wordsFor(node_count: u32) usize {
    return (@as(usize, node_count) + 63) / 64;
}

// ── expand ───────────────────────────────────────────────────────────────

/// Level-synchronous expand: `level(v)` = shortest dir/rel distance from
/// the input set (input nodes are level 0); result = nodes with level in
/// [hops.min, hops.max]. The visited bitmap guarantees each node is
/// expanded at most once — the termination proof for UNBOUNDED and the
/// cost bound are the same fact.
fn execExpand(
    view: *const snapshot_view.CapturedGraphView,
    allocator: std.mem.Allocator,
    input: *const NodeSet,
    step: ir.Step,
) ExecError!NodeSet {
    var result = try NodeSet.create(allocator, input.words.len);
    errdefer result.destroy(allocator);
    var visited = try NodeSet.create(allocator, input.words.len);
    defer visited.destroy(allocator);

    var frontier: std.ArrayList(u32) = .empty;
    defer frontier.deinit(allocator);
    var next_frontier: std.ArrayList(u32) = .empty;
    defer next_frontier.deinit(allocator);

    const include_level_zero = step.hops.min == 0;
    var members = input.iterator();
    while (members.next()) |node_idx| {
        _ = visited.insert(node_idx);
        if (include_level_zero) _ = result.insert(node_idx);
        try frontier.append(allocator, node_idx);
    }

    const max_level: u32 = if (step.hops.max == ir.UNBOUNDED) std.math.maxInt(u32) else step.hops.max;
    var level: u32 = 1;
    while (frontier.items.len != 0 and level <= max_level) : (level += 1) {
        next_frontier.clearRetainingCapacity();
        var sink = ExpandSink{
            .allocator = allocator,
            .visited = &visited,
            .result = &result,
            .next_frontier = &next_frontier,
            .in_range = level >= step.hops.min,
        };
        for (frontier.items) |node_idx| {
            switch (step.dir) {
                .out => try walkOutNeighbors(view, node_idx, step.rel, &sink),
                .in => try walkInNeighbors(view, node_idx, step.rel, &sink),
                .both => {
                    try walkOutNeighbors(view, node_idx, step.rel, &sink);
                    try walkInNeighbors(view, node_idx, step.rel, &sink);
                },
            }
        }
        std.mem.swap(std.ArrayList(u32), &frontier, &next_frontier);
    }
    return result;
}

const ExpandSink = struct {
    allocator: std.mem.Allocator,
    visited: *NodeSet,
    result: *NodeSet,
    next_frontier: *std.ArrayList(u32),
    in_range: bool,

    fn visit(self: *ExpandSink, candidate: u32) !void {
        if (!self.visited.insert(candidate)) return;
        if (self.in_range) _ = self.result.insert(candidate);
        try self.next_frontier.append(self.allocator, candidate);
    }
};

// ── adjacency walks over the captured view ───────────────────────────────
//
// Same traversal scheme and tombstone filters as the snapshot iterators:
// candidates past the snapshot frontier are skipped, and removed
// candidates are filtered only when the side carries repair debt (clean
// sides cannot contain them).

const FwdEntry = struct {
    destination: u32,
    relation: u16,
    prop_row: u32,
};

/// Full-drain forward ENTRY walk (destination + relation + prop row);
/// the relation-aware sibling of the snapshot neighbor walk.
fn forEachFwdEntry(
    view: *const snapshot_view.CapturedGraphView,
    node_idx: u32,
    context: anytype,
    comptime callback: anytype,
) !void {
    const side = snapshot_capture.sideAdjOfSnapshot(view.fwdSide(node_idx));
    if (side.block_count == 0) return;
    const len_bound: u32 = @intCast(view.node_state.len);
    const check_removed = view.needsRepairFwd(node_idx);
    const with_rows = view.core.edge_properties_enabled;

    if (node_published.NodePublished.isTiny(&side)) {
        const slot = page_ops.tinyBlockAtConst(view.core, side.first_block, .fwd);
        const count = node_published.NodePublished.tinyCount(&side);
        for (slot.entries[0..count]) |entry| {
            if (entry.destination >= len_bound) continue;
            if (check_removed and !view.isLiveIndex(entry.destination)) continue;
            try callback(context, FwdEntry{
                .destination = entry.destination,
                .relation = entry.relation,
                .prop_row = entry.prop_row,
            });
        }
        return;
    }

    var cursor = side_ops.BlockCursor.init(side);
    while (cursor.next(view.core)) |block_idx| {
        const alive = page_ops.blockAliveCount(view.core, block_idx, .fwd);
        if (alive == 0) continue;
        const block = page_ops.edgeBlockFwdAtConst(view.core, block_idx);
        const rows: ?*const types.EdgeBlockFwdProps =
            if (with_rows) page_ops.edgeBlockFwdPropsAtConst(view.core, block_idx) else null;
        for (0..alive) |slot| {
            const destination = block.destinations[slot];
            if (destination >= len_bound) continue;
            if (check_removed and !view.isLiveIndex(destination)) continue;
            try callback(context, FwdEntry{
                .destination = destination,
                .relation = block.relations[slot],
                .prop_row = if (rows) |row_block| row_block.rows[slot] else 0,
            });
        }
    }
}

fn walkOutNeighbors(
    view: *const snapshot_view.CapturedGraphView,
    node_idx: u32,
    rel: u16,
    sink: *ExpandSink,
) !void {
    const Filter = struct {
        rel: u16,
        sink: *ExpandSink,
        fn onEntry(self: *const @This(), entry: FwdEntry) !void {
            if (self.rel != ir.ANY_RELATION and entry.relation != self.rel) return;
            try self.sink.visit(entry.destination);
        }
    };
    try forEachFwdEntry(view, node_idx, &Filter{ .rel = rel, .sink = sink }, Filter.onEntry);
}

/// Reverse expansion. Reverse blocks store sources only, so a specific
/// relation is confirmed per candidate against the candidate's forward
/// side (one adjacency scan with early exit).
fn walkInNeighbors(
    view: *const snapshot_view.CapturedGraphView,
    node_idx: u32,
    rel: u16,
    sink: *ExpandSink,
) !void {
    const side = snapshot_capture.sideAdjOfSnapshot(view.revSide(node_idx));
    if (side.block_count == 0) return;
    const len_bound: u32 = @intCast(view.node_state.len);
    const check_removed = view.needsRepairRev(node_idx);

    if (node_published.NodePublished.isTiny(&side)) {
        const slot = page_ops.tinyBlockAtConst(view.core, side.first_block, .rev);
        const count = node_published.NodePublished.tinyCount(&side);
        for (slot.sources[0..count]) |source| {
            try visitInCandidate(view, node_idx, rel, sink, source, len_bound, check_removed);
        }
        return;
    }

    var cursor = side_ops.BlockCursor.init(side);
    while (cursor.next(view.core)) |block_idx| {
        const alive = page_ops.blockAliveCount(view.core, block_idx, .rev);
        if (alive == 0) continue;
        const block = page_ops.edgeBlockRevAtConst(view.core, block_idx);
        for (block.sources[0..alive]) |source| {
            try visitInCandidate(view, node_idx, rel, sink, source, len_bound, check_removed);
        }
    }
}

fn visitInCandidate(
    view: *const snapshot_view.CapturedGraphView,
    node_idx: u32,
    rel: u16,
    sink: *ExpandSink,
    source: u32,
    len_bound: u32,
    check_removed: bool,
) !void {
    if (source >= len_bound) return;
    if (check_removed and !view.isLiveIndex(source)) return;
    if (rel != ir.ANY_RELATION and !hasForwardEdgeWithRelation(view, source, node_idx, rel)) return;
    try sink.visit(source);
}

fn hasForwardEdgeWithRelation(
    view: *const snapshot_view.CapturedGraphView,
    source: u32,
    destination: u32,
    rel: u16,
) bool {
    const Probe = struct {
        destination: u32,
        rel: u16,
        found: bool = false,
        fn onEntry(self: *@This(), entry: FwdEntry) error{Found}!void {
            if (entry.destination == self.destination and entry.relation == self.rel) {
                self.found = true;
                return error.Found;
            }
        }
    };
    var probe = Probe{ .destination = destination, .rel = rel };
    forEachFwdEntry(view, source, &probe, Probe.onEntry) catch {};
    return probe.found;
}

// ── filters ──────────────────────────────────────────────────────────────

/// Keep nodes whose `step.dir` degree (in the FULL snapshot, not the
/// induced subgraph) satisfies `step.cmp step.arg`. In place.
fn execFilterDegree(
    view: *const snapshot_view.CapturedGraphView,
    set: *NodeSet,
    step: ir.Step,
) void {
    var members = set.iterator();
    while (members.next()) |node_idx| {
        const degree: u64 = switch (step.dir) {
            .out => view.degree_fwd[node_idx],
            .in => view.degree_rev[node_idx],
            .both => @as(u64, view.degree_fwd[node_idx]) + view.degree_rev[node_idx],
        };
        const keep = switch (step.cmp) {
            .lt => degree < step.arg,
            .le => degree <= step.arg,
            .eq => degree == step.arg,
            .ge => degree >= step.arg,
            .gt => degree > step.arg,
        };
        if (!keep) {
            set.words[node_idx / 64] &= ~(@as(u64, 1) << @as(u6, @intCast(node_idx % 64)));
            set.count -= 1;
        }
    }
}

// ── set operations ───────────────────────────────────────────────────────

/// Word-wise union/intersect/minus, computed into `lower` (the set pushed
/// first — `set_minus` is lower ∖ top, matching pipeline reading order).
fn execSetOp(op: ir.Op, lower: *NodeSet, top: *const NodeSet) void {
    var count: u32 = 0;
    for (lower.words, top.words) |*lower_word, top_word| {
        lower_word.* = switch (op) {
            .set_union => lower_word.* | top_word,
            .set_intersect => lower_word.* & top_word,
            .set_minus => lower_word.* & ~top_word,
            else => unreachable,
        };
        count += @popCount(lower_word.*);
    }
    lower.count = count;
}

// ── terminals ────────────────────────────────────────────────────────────

fn emitIds(allocator: std.mem.Allocator, set: *const NodeSet) ![]u32 {
    const out = try allocator.alloc(u32, set.count);
    var members = set.iterator();
    var out_idx: usize = 0;
    while (members.next()) |node_idx| : (out_idx += 1) out[out_idx] = node_idx;
    return out;
}

/// Edges with BOTH endpoints in `set`, sorted by (source, destination,
/// prop_row). Multigraph parallel edges appear once each. prop_row = 0
/// when the graph has no edge properties.
fn emitEdges(
    view: *const snapshot_view.CapturedGraphView,
    allocator: std.mem.Allocator,
    set: *const NodeSet,
) ![]ir.EdgeRow {
    var rows: std.ArrayList(ir.EdgeRow) = .empty;
    errdefer rows.deinit(allocator);

    const Collect = struct {
        allocator: std.mem.Allocator,
        rows: *std.ArrayList(ir.EdgeRow),
        set: *const NodeSet,
        source: u32,
        fn onEntry(self: *const @This(), entry: FwdEntry) !void {
            if (!self.set.contains(entry.destination)) return;
            try self.rows.append(self.allocator, .{
                .source = self.source,
                .destination = entry.destination,
                .prop_row = entry.prop_row,
            });
        }
    };

    var members = set.iterator();
    while (members.next()) |node_idx| {
        try forEachFwdEntry(view, node_idx, &Collect{
            .allocator = allocator,
            .rows = &rows,
            .set = set,
            .source = node_idx,
        }, Collect.onEntry);
    }

    const out = try rows.toOwnedSlice(allocator);
    std.mem.sort(ir.EdgeRow, out, {}, struct {
        fn lessThan(_: void, a: ir.EdgeRow, b: ir.EdgeRow) bool {
            if (a.source != b.source) return a.source < b.source;
            if (a.destination != b.destination) return a.destination < b.destination;
            return a.prop_row < b.prop_row;
        }
    }.lessThan);
    return out;
}

/// CSR of the induced subgraph: offsets span ALL node ids (non-members get
/// empty ranges), targets are in-set forward destinations in adjacency
/// order, alive_node_bitmap is the membership bitmap, out_rows aligned with
/// targets when the graph has edge properties.
fn emitCsr(
    view: *const snapshot_view.CapturedGraphView,
    allocator: std.mem.Allocator,
    set: *const NodeSet,
) !snapshot_csr.CsrView {
    const node_count = view.nodeCount();
    const with_rows = view.core.edge_properties_enabled;

    const out_offsets = try allocator.alloc(u64, node_count + 1);
    errdefer allocator.free(out_offsets);
    const alive_node_bitmap = try allocator.alloc(u64, (node_count + 63) / 64);
    errdefer allocator.free(alive_node_bitmap);
    @memset(alive_node_bitmap, 0);
    @memcpy(alive_node_bitmap[0..set.words.len], set.words);

    var out_targets: std.ArrayList(u32) = .empty;
    errdefer out_targets.deinit(allocator);
    var out_rows: std.ArrayList(u32) = .empty;
    errdefer out_rows.deinit(allocator);

    const Collect = struct {
        allocator: std.mem.Allocator,
        targets: *std.ArrayList(u32),
        rows: *std.ArrayList(u32),
        set: *const NodeSet,
        with_rows: bool,
        fn onEntry(self: *const @This(), entry: FwdEntry) !void {
            if (!self.set.contains(entry.destination)) return;
            try self.targets.append(self.allocator, entry.destination);
            if (self.with_rows) try self.rows.append(self.allocator, entry.prop_row);
        }
    };

    for (0..node_count) |idx| {
        const node_idx: u32 = @intCast(idx);
        out_offsets[idx] = out_targets.items.len;
        if (!set.contains(node_idx)) continue;
        try forEachFwdEntry(view, node_idx, &Collect{
            .allocator = allocator,
            .targets = &out_targets,
            .rows = &out_rows,
            .set = set,
            .with_rows = with_rows,
        }, Collect.onEntry);
    }
    out_offsets[node_count] = out_targets.items.len;

    return .{
        .node_count = @intCast(node_count),
        .out_offsets = out_offsets,
        .out_targets = try out_targets.toOwnedSlice(allocator),
        .alive_node_bitmap = alive_node_bitmap,
        .out_rows = if (with_rows) try out_rows.toOwnedSlice(allocator) else blk: {
            out_rows.deinit(allocator);
            break :blk null;
        },
    };
}

comptime {
    std.debug.assert(constants.END_OF_CHAIN == 0xFFFF_FFFF);
}
