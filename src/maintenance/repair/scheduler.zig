//! Repair scheduling — budgeted repair worker, node selection, and budget tracking.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
const rebuild_mod = @import("rebuild.zig");

pub fn repairNodeSideLimited(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    if (max_compactions == 0) return 0;

    var node_mut = page_ops.nodeAt(graph, node);
    try rebuild_mod.claimNodeForPublish(node_mut);
    defer rebuild_mod.releaseNodeForPublish(node_mut);

    const published_adj = node_mut.publishedAdj();
    if (!node_validity.snapshotIsLive(published_adj)) return 0;

    if (side == .fwd) {
        const compacted_tombstones = try rebuild_mod.repairForwardTombstonesWithReverseCleanup(graph, node, node_mut);
        if (compacted_tombstones > 0) return compacted_tombstones;
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    const node_adj = published_adj;
    const first_block: u32 = if (side == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    const block_count: u16 = if (side == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    const group_count: u16 = if (side == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    const first_group: u32 = if (side == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;

    if (block_count <= 1) {
        if (block_count == 0) return 0;
        // Single block with repair debt: tombstones (detected by
        // computeNeedsRepair) or grouped layout awaiting canonicalization
        // (group_count > 0 — not detected by computeNeedsRepair for
        // single blocks but the flag is already set).
        if (!debt_mod.computeNeedsRepair(graph, &node_adj, side) and group_count == 0) return 0;
        // Fall through to rebuild.
    }

    // Single-pass compaction with k-way merge: read sorted entries from
    // all blocks, merge by key, pack into new blocks.  O(E log B).
    var staging_adj = published_adj;

    var total_live: usize = 0;
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            total_live += @popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask);
        }
    } else {
        var group_idx = first_group;
        var visit_count: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            if (group_idx >= graph.group_count) return error.CorruptGraph;
            if (visit_count >= group_count or visit_count >= graph.group_count) return error.CorruptGraph;
            visit_count += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                total_live += @popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask);
            }
            group_idx = group.next;
        }
    }

    if (!debt_mod.computeNeedsRepair(graph, &staging_adj, side)) {
        debt_mod.updateRepairDebt(graph, &staging_adj, node.index, side);
        return 0;
    }

    var sorted = switch (side) {
        .fwd => try rebuild_mod.sortedRebuildForward(graph, first_block, block_count, group_count, first_group, graph.allocator),
        .rev => try rebuild_mod.sortedRebuildReverse(graph, first_block, block_count, group_count, first_group, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);
    const live_total: usize = sorted.live_after;

    var scratch = mutation_common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    try scratch.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    {
        var tmp: types.SideAdj = undefined;
        try mutation_common.buildSideFromBlocks(&tmp, graph, sorted.new_blocks.items, &scratch);
        switch (side) {
            .fwd => {
                staging_adj.first_block_fwd = tmp.first_block;
                staging_adj.block_count_fwd = tmp.block_count;
                staging_adj.group_count_fwd = tmp.group_count;
                staging_adj.first_group_fwd = tmp.first_group;
            },
            .rev => {
                staging_adj.first_block_rev = tmp.first_block;
                staging_adj.block_count_rev = tmp.block_count;
                staging_adj.group_count_rev = tmp.group_count;
                staging_adj.first_group_rev = tmp.first_group;
            },
        }
    }

    debt_mod.updateRepairDebt(graph, &staging_adj, node.index, side);
    const meta = node_mut.loadPublishedMeta();
    const new_live: u22 = @as(u22, @intCast(live_total));
    scratch.disarm();
    mutation_common.publishBothAdj(node_mut, staging_adj,
        if (side == .fwd) new_live else meta.degree_fwd,
        if (side == .rev) new_live else meta.degree_rev);

    // Retire old side using the shared primitive.
    try mutation_common.retireSide(graph, published_adj, side);
    return 1;
}

/// Merge under-full blocks in a single node's forward or reverse adjacency.
/// Returns the number of block-pair compactions performed (0 if everything
/// already met the threshold).
pub fn repairNodeSide(graph: *graph_core.GraphCore, node: types.NodeId, comptime side: adjacency.AdjSide) !usize {
    return repairNodeSideLimited(graph, node, side, std.math.maxInt(usize));
}

/// Public RFC repair entry point: repair both forward and reverse adjacency
/// for a single node. The side-specific primitive remains available to tests
/// and internal code as `repairNodeSide`, but the public graph API is side-free.
pub fn repairNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (!node_validity.isNodeLive(graph, node)) return error.InvalidNode;

    const compacted_fwd = try repairNodeSide(graph, node, .fwd);
    const compacted_rev = try repairNodeSide(graph, node, .rev);
    if (compacted_fwd + compacted_rev > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }
}

fn processedNodeContains(processed_nodes: []const u32, node_index: u32) bool {
    for (processed_nodes) |processed| {
        if (processed == node_index) return true;
    }
    return false;
}

fn isEligibleRepairCandidate(graph: *const graph_core.GraphCore, processed_nodes: []const u32, node_index: u32) bool {
    if (processedNodeContains(processed_nodes, node_index)) return false;
    return node_validity.isNodeLiveIndex(graph, node_index);
}

fn findTombstoneDebtByScan(graph: *graph_core.GraphCore) ?u32 {
    const reader_token = rcu.readerEnter(graph);
    defer rcu.readerExit(graph, reader_token);

    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;

    const cursor = &graph.repair_scan_cursor_tombstone;
    if (cursor.* >= node_count) cursor.* = 0;

    var node_index = cursor.*;
    while (node_index < node_count) : (node_index += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_index)) continue;
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
        if (adj.block_count_fwd == 0) continue;
        if (rebuild_mod.hasAnyTombstone(graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, .fwd)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }

    node_index = 0;
    while (node_index < cursor.*) : (node_index += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_index)) continue;
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
        if (adj.block_count_fwd == 0) continue;
        if (rebuild_mod.hasAnyTombstone(graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, .fwd)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }

    return null;
}

fn nextRepairDebtNode(graph: *graph_core.GraphCore, processed_nodes: []const u32) ?u32 {
    if (debt_mod.popRepairDebtBestEffort(graph, .fwd)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (debt_mod.popRepairDebtBestEffort(graph, .rev)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .fwd)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .rev)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (findTombstoneDebtByScan(graph)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    return null;
}

/// Run up to `max_nodes` repair operations across the repair debt queue.
/// Each operation repairs at most one distinct node (both sides if needed).
/// Returns the number of nodes repaired.
pub fn repairBudgeted(graph: *graph_core.GraphCore, max_nodes: usize) !usize {
    if (graph.active_repairers.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        return error.ConcurrentMutation;
    }
    defer graph.active_repairers.store(0, .release);

    var total_compacted: usize = 0;
    var processed_nodes: std.ArrayList(u32) = .empty;
    defer processed_nodes.deinit(graph.allocator);

    while (total_compacted < max_nodes) {
        const node_index = nextRepairDebtNode(graph, processed_nodes.items) orelse break;
        try processed_nodes.append(graph.allocator, node_index);

        const compacted_fwd = try repairNodeSideLimited(graph, .{ .index = node_index }, .fwd, std.math.maxInt(usize));
        const compacted_rev = try repairNodeSideLimited(graph, .{ .index = node_index }, .rev, std.math.maxInt(usize));
        if (compacted_fwd + compacted_rev > 0) total_compacted += 1;
    }

    if (total_compacted > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }

    return total_compacted;
}
