//! Side repair application and publish flow.

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
const rebuild_mod = @import("rebuild.zig");

const RepairPreparation = struct {
    node_mut: *types.NodeBuffer,
    published_adj: types.NodeAdj,
    published_side: types.SideAdj,
};

const RepairRebuild = struct {
    staging_adj: types.NodeAdj,
    live_total: usize,
};

/// Repairs both published sides of one node and reports whether anything changed.
pub fn repairBothSides(graph: *graph_core.GraphCore, node: types.NodeId) !bool {
    const compacted_fwd = try repairNodeSideLimited(graph, node, .fwd, std.math.maxInt(usize));
    const compacted_rev = try repairNodeSideLimited(graph, node, .rev, std.math.maxInt(usize));
    return compacted_fwd + compacted_rev > 0;
}

fn prepareRepairTarget(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !?RepairPreparation {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    if (max_compactions == 0) return null;

    const node_mut = page_ops.nodeAt(graph, node);
    const published_adj = node_mut.publishedAdj();
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

fn shouldSkipRepair(
    graph: *graph_core.GraphCore,
    node_mut: *types.NodeBuffer,
    published_adj: *const types.NodeAdj,
    published_side: *const types.SideAdj,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) bool {
    if (published_side.block_count <= 1) {
        if (published_side.block_count == 0) return true;
        if (!debt_mod.computeNeedsRepair(graph, published_adj, side) and published_side.group_count == 0) {
            debt_mod.updateRepairDebtSide(graph, node_mut, node_idx, side);
            return true;
        }
    }

    var staging_adj = published_adj.*;
    if (!debt_mod.computeNeedsRepair(graph, &staging_adj, side)) {
        debt_mod.updateRepairDebtSide(graph, node_mut, node_idx, side);
        return true;
    }

    return false;
}

fn rebuildSideForRepair(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    published_adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !RepairRebuild {
    var sorted = switch (side) {
        .fwd => try rebuild_mod.sortedRebuildForward(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, graph.allocator),
        .rev => try rebuild_mod.sortedRebuildReverse(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);

    var scratch = mutation_common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    try scratch.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    var staging_adj = published_adj.*;
    var rebuilt_side: types.SideAdj = undefined;
    try side_adj.buildSideFromBlocks(&rebuilt_side, graph, sorted.new_blocks.items, &scratch);
    side_adj.writeSide(&staging_adj, side, rebuilt_side);
    scratch.disarm();

    return .{
        .staging_adj = staging_adj,
        .live_total = sorted.live_after,
    };
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
    const meta = node_mut.loadPublishedMeta();
    const new_live: u22 = @intCast(live_total);

    side_adj.publishBothAdj(node_mut, staging_adj.*, switch (side) {
        .fwd => new_live,
        .rev => meta.degree_fwd,
    }, switch (side) {
        .fwd => meta.degree_rev,
        .rev => new_live,
    });

    try side_adj.retireSide(graph, published_adj, side);
    return 1;
}

/// Repairs one published side of one node, honoring the caller's compaction budget.
/// Returns the number of repair actions performed for that side.
pub fn repairNodeSideLimited(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !usize {
    const preparation = (try prepareRepairTarget(graph, node, side, max_compactions)) orelse return 0;

    const node_mut = preparation.node_mut;
    const published_adj = preparation.published_adj;
    const published_side = preparation.published_side;

    try rebuild_mod.claimNodeForPublish(node_mut);
    defer rebuild_mod.releaseNodeForPublish(node_mut);

    if (try tryCompactForwardTombstones(graph, node, node_mut, side)) |compacted_tombstones| {
        return compacted_tombstones;
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    if (shouldSkipRepair(graph, node_mut, &published_adj, &published_side, node.index, side)) return 0;

    var rebuild = try rebuildSideForRepair(graph, &published_side, &published_adj, side);
    return publishRepairedSide(graph, node_mut, published_adj, &rebuild.staging_adj, node.index, rebuild.live_total, side);
}

/// Repairs one side of one node without an explicit compaction limit.
pub fn repairNodeSide(graph: *graph_core.GraphCore, node: types.NodeId, comptime side: adjacency.AdjSide) !usize {
    return repairNodeSideLimited(graph, node, side, std.math.maxInt(usize));
}

/// Repairs both sides of one live node and bumps the epoch on success.
pub fn repairNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (!node_validity.isNodeLive(graph, node)) return error.InvalidNode;

    if (try repairBothSides(graph, node)) {
        rcu.bumpEpoch(graph);
    }
}
