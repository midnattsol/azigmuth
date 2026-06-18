//! Side repair application and publish flow.

const std = @import("std");
const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_adjacency_buffers = @import("../../../storage/node/adjacency_buffers.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const rcu = @import("../../../concurrency/rcu.zig");
const node_validity = @import("../../../core/node_validity.zig");
const side_adj = @import("../../../adjacency/side_ops.zig");
const mutation_common = @import("../../../mutation/common.zig");
const debt_mod = @import("../debt.zig");
const rebuild_mod = @import("../rebuild.zig");
const side_rebuild_apply = @import("../side_rebuild_apply.zig");

const RepairPreparation = struct {
    published_adj: types.NodeAdj,
    published_side: types.SideAdj,
};

const RepairRebuild = struct {
    staging_adj: types.NodeAdj,
    alive_total: usize,
    dropped_prop_rows: std.ArrayList(u32) = .empty,
};

const PublishedDegrees = struct {
    fwd: u32,
    rev: u32,
};

/// Per-side outcome of a repair attempt, feeding `RepairNodeSummary`.
pub const SideRepairOutcome = struct {
    repaired: bool = false,
    preventive: bool = false,
    had_flagged_debt: bool = false,
    left_repair_debt: bool = false,
};

/// Repairs both published sides of one node and reports whether anything changed.
/// Budgeted/flush callers process only published debt — never preventive work.
pub fn repairBothSides(graph: *graph_core.GraphCore, node: types.NodeId) !bool {
    const outcome_fwd = try repairNodeSideDetailed(graph, node, .fwd, false);
    const outcome_rev = try repairNodeSideDetailed(graph, node, .rev, false);
    return outcome_fwd.repaired or outcome_rev.repaired;
}

/// True when the side is in compact canonical form: empty, tiny, or a single
/// contiguous segment whose non-tail blocks are all full. A non-canonical side is
/// the layout precondition for mutation-side `RepairRequired`, so explicit
/// `repairNode` rebuilds it preventively.
fn sideIsCanonical(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
) bool {
    if (side_view.block_count == 0) return true;
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_view)) return true;
    if (side_view.segment_count != 0) return false;

    const tail_block_idx = side_view.first_block + side_view.block_count - 1;
    for (side_view.first_block..tail_block_idx) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const alive = page_ops.blockAliveCount(graph, block_idx, side);
        if (alive != constants.EDGES_PER_BLOCK) return false;
    }
    return true;
}

fn prepareRepairTarget(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !?RepairPreparation {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    if (max_compactions == 0) return null;

    const published_adj = node_access.publishedAdjAtConst(graph, node);
    if (!node_validity.snapshotIsLive(published_adj)) return null;

    return .{
        .published_adj = published_adj,
        .published_side = side_adj.sideAdjOfNode(published_adj, side),
    };
}

fn tryCompactForwardTombstones(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
) !?usize {
    if (side != .fwd) return null;

    const compacted_tombstones = try rebuild_mod.compactForwardTombstones(graph, node);
    if (compacted_tombstones > 0) return compacted_tombstones;
    return null;
}

fn needsRepairWork(
    graph: *graph_core.GraphCore,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) bool {
    return debt_mod.refreshPublishedRepairDebt(graph, node_idx, side) == .repair;
}

fn rebuildTinyReverseSideForRepair(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    published_adj: *const types.NodeAdj,
) !RepairRebuild {
    const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(published_side);
    const slot = page_ops.tinySlotAtConst(graph, published_side.first_block, .rev);

    var alive_total: u16 = 0;
    for (0..count) |entry_idx| {
        const source_idx = slot.sources[entry_idx];
        if (source_idx < graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(graph, source_idx)) {
            alive_total += 1;
        }
    }

    var staging_adj = published_adj.*;
    if (alive_total == 0) {
        side_adj.writeSide(&staging_adj, .rev, std.mem.zeroes(types.SideAdj));
        return .{ .staging_adj = staging_adj, .alive_total = 0 };
    }

    const new_slot_idx = try page_ops.allocTinySlotRaw(graph, .rev);
    const new_block = page_ops.tinySlotAt(graph, new_slot_idx, .rev);
    var write_idx: u16 = 0;
    for (0..count) |entry_idx| {
        const source_idx = slot.sources[entry_idx];
        if (source_idx >= graph.publishedNodeCount() or node_validity.isNodeRemovedIndex(graph, source_idx)) continue;
        new_block.sources[write_idx] = source_idx;
        write_idx += 1;
    }

    side_adj.writeSide(&staging_adj, .rev, node_adjacency_buffers.NodeAdjacencyBuffers.makeTiny(new_slot_idx, write_idx));
    return .{ .staging_adj = staging_adj, .alive_total = write_idx };
}

fn rebuildSideForRepair(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    published_adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !RepairRebuild {
    if (side == .rev and node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(published_side)) {
        return rebuildTinyReverseSideForRepair(graph, published_side, published_adj);
    }

    var sorted = switch (side) {
        .fwd => try rebuild_mod.sortedRebuildForward(graph, published_side.first_block, published_side.block_count, published_side.segment_count, published_side.first_segment, graph.allocator),
        .rev => try rebuild_mod.sortedRebuildReverse(graph, published_side.first_block, published_side.block_count, published_side.segment_count, published_side.first_segment, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);
    errdefer sorted.dropped_prop_rows.deinit(graph.allocator);

    var scratch = mutation_common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    var staging_adj = published_adj.*;
    const rebuilt_side = try side_rebuild_apply.adoptSortedRebuildSide(graph, side, &sorted, &scratch);
    side_adj.writeSide(&staging_adj, side, rebuilt_side);
    scratch.disarm();

    const dropped_rows = sorted.dropped_prop_rows;
    sorted.dropped_prop_rows = .empty;
    return .{
        .staging_adj = staging_adj,
        .alive_total = sorted.alive_after,
        .dropped_prop_rows = dropped_rows,
    };
}

fn repairedDegrees(
    graph: *const graph_core.GraphCore,
    node: types.NodeId,
    state: types.NodePublicationState,
    alive_total: usize,
    comptime side: adjacency.AdjSide,
) PublishedDegrees {
    const new_alive_count: u32 = @intCast(alive_total);
    return switch (side) {
        .fwd => .{ .fwd = new_alive_count, .rev = node_access.publishedRevDegreeFromStateAtConst(graph, node, state) },
        .rev => .{ .fwd = node_access.publishedFwdDegreeFromStateAtConst(graph, node, state), .rev = new_alive_count },
    };
}

fn publishRepairedAdjacency(
    graph: *graph_core.GraphCore,
    node_idx: u32,
    staging_adj: types.NodeAdj,
    degrees: PublishedDegrees,
    comptime rebuilt_side: adjacency.AdjSide,
) !void {
    const buffers_ref = page_ops.nodeAdjacencyBuffersAt(graph, .{ .index = node_idx });
    const state = node_access.loadPublicationStateAtConst(graph, .{ .index = node_idx });
    // The rebuilt side is emitted in sorted order; the other side keeps its
    // current published sortedness.
    const sorted_fwd = if (rebuilt_side == .fwd) true else buffers_ref.publishedFwdSortedFromState(state);
    const sorted_rev = if (rebuilt_side == .rev) true else buffers_ref.publishedRevSortedFromState(state);
    side_adj.publishBothAdj(
        graph,
        .{ .index = node_idx },
        page_ops.nodePublicationAt(graph, .{ .index = node_idx }),
        buffers_ref,
        staging_adj,
        degrees.fwd,
        degrees.rev,
        sorted_fwd,
        sorted_rev,
    );
}

fn publishRepairedSide(
    graph: *graph_core.GraphCore,
    published_adj: types.NodeAdj,
    staging_adj: *types.NodeAdj,
    node_idx: u32,
    alive_total: usize,
    comptime side: adjacency.AdjSide,
) !usize {
    debt_mod.updateRepairDebt(graph, staging_adj, node_idx, side);
    const state = node_access.loadPublicationStateAtConst(graph, .{ .index = node_idx });
    const degrees = repairedDegrees(graph, .{ .index = node_idx }, state, alive_total, side);

    try publishRepairedAdjacency(graph, node_idx, staging_adj.*, degrees, side);

    try side_adj.retireSide(graph, published_adj, side);
    return 1;
}

fn repairPublishedSide(
    graph: *graph_core.GraphCore,
    published_adj: types.NodeAdj,
    published_side: types.SideAdj,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
    allow_preventive: bool,
) !SideRepairOutcome {
    var outcome = SideRepairOutcome{};

    const flagged = needsRepairWork(graph, node_idx, side);
    if (!flagged) {
        if (!allow_preventive or sideIsCanonical(graph, published_side, side)) {
            outcome.left_repair_debt = sideFlagAfter(graph, node_idx, side);
            return outcome;
        }
        outcome.preventive = true;
    }

    var rebuild = try rebuildSideForRepair(graph, &published_side, &published_adj, side);
    defer rebuild.dropped_prop_rows.deinit(graph.allocator);
    _ = try publishRepairedSide(graph, published_adj, &rebuild.staging_adj, node_idx, rebuild.alive_total, side);
    for (rebuild.dropped_prop_rows.items) |row| rcu.retirePropRow(graph, row);
    outcome.repaired = true;
    outcome.left_repair_debt = sideFlagAfter(graph, node_idx, side);
    return outcome;
}

fn sideFlagAfter(graph: *const graph_core.GraphCore, node_idx: u32, comptime side: adjacency.AdjSide) bool {
    const state = node_access.loadPublicationStateAtConst(graph, .{ .index = node_idx });
    return switch (side) {
        .fwd => state.needs_repair_fwd,
        .rev => state.needs_repair_rev,
    };
}

/// Repairs one published side of one node and reports the detailed outcome.
/// `allow_preventive` is the explicit-repairNode privilege: rebuild even when
/// no debt is flagged, so layout-blocked mutations have a guaranteed retry.
pub fn repairNodeSideDetailed(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    allow_preventive: bool,
) !SideRepairOutcome {
    const preparation = (try prepareRepairTarget(graph, node, side, std.math.maxInt(usize))) orelse return .{};

    const published_adj = preparation.published_adj;
    const published_side = preparation.published_side;

    const had_flagged_debt = switch (side) {
        .fwd => published_adj.flags.needs_repair_fwd,
        .rev => published_adj.flags.needs_repair_rev,
    };

    try rebuild_mod.claimNodeForPublish(graph, node);
    defer rebuild_mod.releaseNodeForPublish(graph, node);

    if (try tryCompactForwardTombstones(graph, node, side)) |compacted_tombstones| {
        _ = compacted_tombstones;
        return .{
            .repaired = true,
            .had_flagged_debt = had_flagged_debt,
            .left_repair_debt = sideFlagAfter(graph, node.index, side),
        };
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    var outcome = try repairPublishedSide(graph, published_adj, published_side, node.index, side, allow_preventive);
    outcome.had_flagged_debt = had_flagged_debt;
    return outcome;
}

/// Repairs one side of one node, returning 1 when a repair was performed.
pub fn repairNodeSide(graph: *graph_core.GraphCore, node: types.NodeId, comptime side: adjacency.AdjSide) !usize {
    const outcome = try repairNodeSideDetailed(graph, node, side, false);
    return if (outcome.repaired) 1 else 0;
}

/// Explicitly repairs both sides of one live node, including preventive
/// layout hardening, and bumps the epoch when anything was rebuilt.
pub fn repairNode(graph: *graph_core.GraphCore, node: types.NodeId) !types.RepairNodeSummary {
    if (!node_validity.isNodeLive(graph, node)) return error.InvalidNode;

    const outcome_fwd = try repairNodeSideDetailed(graph, node, .fwd, true);
    const outcome_rev = try repairNodeSideDetailed(graph, node, .rev, true);

    if (outcome_fwd.repaired or outcome_rev.repaired) {
        rcu.bumpEpoch(graph);
    }

    return .{
        .repaired_fwd = outcome_fwd.repaired,
        .repaired_rev = outcome_rev.repaired,
        .preventive_fwd = outcome_fwd.preventive,
        .preventive_rev = outcome_rev.preventive,
        .had_flagged_debt_fwd = outcome_fwd.had_flagged_debt,
        .had_flagged_debt_rev = outcome_rev.had_flagged_debt,
        .left_repair_debt_fwd = outcome_fwd.left_repair_debt,
        .left_repair_debt_rev = outcome_rev.left_repair_debt,
    };
}
