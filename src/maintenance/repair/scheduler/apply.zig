//! Side repair application and publish flow.

const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
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
    node_mut: *types.NodeBuffer,
    published_adj: types.NodeAdj,
    published_side: types.SideAdj,
};

const RepairRebuild = struct {
    staging_adj: types.NodeAdj,
    live_total: usize,
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
/// contiguous run whose non-tail blocks are all full. A non-canonical side is
/// the layout precondition for mutation-side `RepairRequired`, so explicit
/// `repairNode` rebuilds it preventively.
fn sideIsCanonical(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
) bool {
    if (side_view.block_count == 0) return true;
    if (node_published.NodePublished.isTiny(&side_view)) return true;
    if (side_view.group_count != 0) return false;

    const tail_block_idx = side_view.first_block + side_view.block_count - 1;
    for (side_view.first_block..tail_block_idx) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const live = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, side).mask);
        if (live != 64) return false;
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

    const node_mut = node_access.nodeAt(graph, node);
    const published_adj = node_access.publishedAdjAtConst(graph, node);
    if (!node_validity.snapshotIsLive(published_adj)) return null;

    return .{
        .node_mut = node_mut,
        .published_adj = published_adj,
        .published_side = side_adj.sideAdjOfNode(published_adj, side),
    };
}

fn tryCompactForwardTombstones(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    node_mut: *types.NodeBuffer,
    comptime side: adjacency.AdjSide,
) !?usize {
    if (side != .fwd) return null;

    const compacted_tombstones = try rebuild_mod.compactForwardTombstones(graph, node, node_mut);
    if (compacted_tombstones > 0) return compacted_tombstones;
    return null;
}

fn needsRepairWork(
    graph: *graph_core.GraphCore,
    node_mut: *types.NodeBuffer,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) bool {
    return debt_mod.refreshPublishedRepairDebt(graph, node_mut, node_idx, side) == .repair;
}

fn rebuildTinyReverseSideForRepair(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    published_adj: *const types.NodeAdj,
) !RepairRebuild {
    const count = node_published.NodePublished.tinyCount(published_side);
    const slot = page_ops.tinyRevAtConst(graph, published_side.first_block);

    var live_total: u16 = 0;
    for (0..count) |entry_idx| {
        const source_idx = slot.sources[entry_idx];
        if (source_idx < graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(graph, source_idx)) {
            live_total += 1;
        }
    }

    var staging_adj = published_adj.*;
    if (live_total == 0) {
        side_adj.writeSide(&staging_adj, .rev, std.mem.zeroes(types.SideAdj));
        return .{ .staging_adj = staging_adj, .live_total = 0 };
    }

    const new_slot_idx = try page_ops.allocTinyRevSlot(graph);
    const new_slot = page_ops.tinyRevAt(graph, new_slot_idx);
    var write_idx: u16 = 0;
    for (0..count) |entry_idx| {
        const source_idx = slot.sources[entry_idx];
        if (source_idx >= graph.publishedNodeCount() or node_validity.isNodeRemovedIndex(graph, source_idx)) continue;
        new_slot.sources[write_idx] = source_idx;
        write_idx += 1;
    }

    side_adj.writeSide(&staging_adj, .rev, node_published.NodePublished.makeTiny(new_slot_idx, write_idx));
    return .{ .staging_adj = staging_adj, .live_total = write_idx };
}

fn rebuildSideForRepair(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    published_adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !RepairRebuild {
    if (side == .rev and node_published.NodePublished.isTiny(published_side)) {
        return rebuildTinyReverseSideForRepair(graph, published_side, published_adj);
    }

    var sorted = switch (side) {
        .fwd => try rebuild_mod.sortedRebuildForward(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, graph.allocator),
        .rev => try rebuild_mod.sortedRebuildReverse(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);

    var scratch = mutation_common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    var staging_adj = published_adj.*;
    const rebuilt_side = try side_rebuild_apply.adoptSortedRebuildSide(graph, side, &sorted, &scratch);
    side_adj.writeSide(&staging_adj, side, rebuilt_side);
    scratch.disarm();

    return .{
        .staging_adj = staging_adj,
        .live_total = sorted.live_after,
    };
}

fn repairedDegrees(
    graph: *const graph_core.GraphCore,
    node: types.NodeId,
    meta: types.PublishedMeta,
    live_total: usize,
    comptime side: adjacency.AdjSide,
) PublishedDegrees {
    const new_live: u32 = @intCast(live_total);
    return switch (side) {
        .fwd => .{ .fwd = new_live, .rev = node_access.publishedRevDegreeFromMetaAtConst(graph, node, meta) },
        .rev => .{ .fwd = node_access.publishedFwdDegreeFromMetaAtConst(graph, node, meta), .rev = new_live },
    };
}

fn publishRepairedAdjacency(
    graph: *graph_core.GraphCore,
    node_mut: *types.NodeBuffer,
    node_idx: u32,
    staging_adj: types.NodeAdj,
    degrees: PublishedDegrees,
    comptime rebuilt_side: adjacency.AdjSide,
) !void {
    const published_ref = try page_ops.ensureNodePublishedAt(graph, .{ .index = node_idx });
    const meta = node_access.loadPublishedMeta(node_mut);
    // The rebuilt side is emitted in sorted order; the other side keeps its
    // current published sortedness.
    const fwd_sorted = if (rebuilt_side == .fwd) true else published_ref.publishedFwdSortedFromMeta(meta);
    const rev_sorted = if (rebuilt_side == .rev) true else published_ref.publishedRevSortedFromMeta(meta);
    side_adj.publishBothAdj(
        graph,
        .{ .index = node_idx },
        page_ops.nodeMetaAt(graph, .{ .index = node_idx }),
        published_ref,
        node_mut,
        staging_adj,
        degrees.fwd,
        degrees.rev,
        fwd_sorted,
        rev_sorted,
    );
}

fn publishRepairedSide(
    graph: *graph_core.GraphCore,
    node_mut: *types.NodeBuffer,
    published_adj: types.NodeAdj,
    staging_adj: *types.NodeAdj,
    node_idx: u32,
    live_total: usize,
    comptime side: adjacency.AdjSide,
) !usize {
    debt_mod.updateRepairDebt(graph, staging_adj, node_idx, side);
    const meta = node_access.loadPublishedMeta(node_mut);
    const degrees = repairedDegrees(graph, .{ .index = node_idx }, meta, live_total, side);

    try publishRepairedAdjacency(graph, node_mut, node_idx, staging_adj.*, degrees, side);

    try side_adj.retireSide(graph, published_adj, side);
    return 1;
}

fn repairPublishedSide(
    graph: *graph_core.GraphCore,
    node_mut: *types.NodeBuffer,
    published_adj: types.NodeAdj,
    published_side: types.SideAdj,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
    allow_preventive: bool,
) !SideRepairOutcome {
    var outcome = SideRepairOutcome{};

    const flagged = needsRepairWork(graph, node_mut, node_idx, side);
    if (!flagged) {
        if (!allow_preventive or sideIsCanonical(graph, published_side, side)) {
            outcome.left_repair_debt = sideFlagAfter(node_mut, side);
            return outcome;
        }
        outcome.preventive = true;
    }

    var rebuild = try rebuildSideForRepair(graph, &published_side, &published_adj, side);
    _ = try publishRepairedSide(graph, node_mut, published_adj, &rebuild.staging_adj, node_idx, rebuild.live_total, side);
    outcome.repaired = true;
    outcome.left_repair_debt = sideFlagAfter(node_mut, side);
    return outcome;
}

fn sideFlagAfter(node_mut: *const types.NodeBuffer, comptime side: adjacency.AdjSide) bool {
    const meta = node_access.loadPublishedMeta(node_mut);
    return switch (side) {
        .fwd => meta.needs_repair_fwd,
        .rev => meta.needs_repair_rev,
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

    const node_mut = preparation.node_mut;
    const published_adj = preparation.published_adj;
    const published_side = preparation.published_side;

    const had_flagged_debt = switch (side) {
        .fwd => published_adj.flags.needs_repair_fwd,
        .rev => published_adj.flags.needs_repair_rev,
    };

    try rebuild_mod.claimNodeForPublish(graph, node);
    defer rebuild_mod.releaseNodeForPublish(graph, node);

    if (try tryCompactForwardTombstones(graph, node, node_mut, side)) |compacted_tombstones| {
        _ = compacted_tombstones;
        return .{
            .repaired = true,
            .had_flagged_debt = had_flagged_debt,
            .left_repair_debt = sideFlagAfter(node_mut, side),
        };
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    var outcome = try repairPublishedSide(graph, node_mut, published_adj, published_side, node.index, side, allow_preventive);
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
