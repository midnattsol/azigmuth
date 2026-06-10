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
) !void {
    side_adj.publishBothAdj(
        graph,
        .{ .index = node_idx },
        page_ops.nodeMetaAt(graph, .{ .index = node_idx }),
        try page_ops.ensureNodePublishedAt(graph, .{ .index = node_idx }),
        node_mut,
        staging_adj,
        degrees.fwd,
        degrees.rev,
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

    try publishRepairedAdjacency(graph, node_mut, node_idx, staging_adj.*, degrees);

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
) !usize {
    if (!needsRepairWork(graph, node_mut, node_idx, side)) return 0;

    var rebuild = try rebuildSideForRepair(graph, &published_side, &published_adj, side);
    return publishRepairedSide(graph, node_mut, published_adj, &rebuild.staging_adj, node_idx, rebuild.live_total, side);
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

    try rebuild_mod.claimNodeForPublish(graph, node);
    defer rebuild_mod.releaseNodeForPublish(graph, node);

    if (try tryCompactForwardTombstones(graph, node, node_mut, side)) |compacted_tombstones| {
        return compacted_tombstones;
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    return repairPublishedSide(graph, node_mut, published_adj, published_side, node.index, side);
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
