//! Repair scheduling — budgeted repair worker, node selection, and budget tracking.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../side_adj.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
const rebuild_mod = @import("rebuild.zig");

fn scanTombstoneRange(graph: *graph_core.GraphCore, start: u32, end: u32) ?u32 {
    var node_idx = start;
    while (node_idx < end) : (node_idx += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_idx)) continue;
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_idx }).publishedAdj();
        if (adj.block_count_fwd == 0) continue;
        if (rebuild_mod.hasAnyTombstone(graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, .fwd)) {
            return node_idx;
        }
    }
    return null;
}

fn repairBothSides(graph: *graph_core.GraphCore, node: types.NodeId) !bool {
    const compacted_fwd = try repairNodeSideLimited(graph, node, .fwd, std.math.maxInt(usize));
    const compacted_rev = try repairNodeSideLimited(graph, node, .rev, std.math.maxInt(usize));
    return compacted_fwd + compacted_rev > 0;
}

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
        const compacted_tombstones = try rebuild_mod.compactForwardTombstones(graph, node, node_mut);
        if (compacted_tombstones > 0) return compacted_tombstones;
    }

    var writer_guard = rebuild_mod.beginWriter(graph);
    defer writer_guard.end();

    const published_side = side_adj.sideAdjOfNode(published_adj, side);

    if (published_side.block_count <= 1) {
        if (published_side.block_count == 0) return 0;
        // Single block with repair debt: tombstones (detected by
        // computeNeedsRepair) or grouped layout awaiting canonicalization
        // (group_count > 0 — not detected by computeNeedsRepair for
        // single blocks but the flag is already set).
        if (!debt_mod.computeNeedsRepair(graph, &published_adj, side) and published_side.group_count == 0) {
            debt_mod.updateRepairDebtSide(graph, node_mut, node.index, side);
            return 0;
        }
        // Fall through to rebuild.
    }

    // Single-pass compaction with k-way merge: read sorted entries from
    // all blocks, merge by key, pack into new blocks.  O(E log B).
    var staging_adj = published_adj;

    if (!debt_mod.computeNeedsRepair(graph, &staging_adj, side)) {
        debt_mod.updateRepairDebtSide(graph, node_mut, node.index, side);
        return 0;
    }

    var sorted = switch (side) {
        .fwd => try rebuild_mod.sortedRebuildForward(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, graph.allocator),
        .rev => try rebuild_mod.sortedRebuildReverse(graph, published_side.first_block, published_side.block_count, published_side.group_count, published_side.first_group, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);
    const live_total: usize = sorted.live_after;

    var scratch = mutation_common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    try scratch.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    {
        var tmp: types.SideAdj = undefined;
        try side_adj.buildSideFromBlocks(&tmp, graph, sorted.new_blocks.items, &scratch);
        side_adj.writeSide(&staging_adj, side, tmp);
    }

    debt_mod.updateRepairDebt(graph, &staging_adj, node.index, side);
    const meta = node_mut.loadPublishedMeta();
    const new_live: u22 = @intCast(live_total);
    scratch.disarm();
    side_adj.publishBothAdj(node_mut, staging_adj, switch (side) {
        .fwd => new_live,
        .rev => meta.degree_fwd,
    }, switch (side) {
        .fwd => meta.degree_rev,
        .rev => new_live,
    });

    // Retire old side using the shared primitive.
    try side_adj.retireSide(graph, published_adj, side);
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

    if (try repairBothSides(graph, node)) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }
}

fn isEligibleRepairCandidate(graph: *const graph_core.GraphCore, processed_nodes: *const std.AutoHashMap(u32, void), node_index: u32) bool {
    if (processed_nodes.contains(node_index)) return false;
    return node_validity.isNodeLiveIndex(graph, node_index);
}

fn findTombstoneDebtByScan(graph: *graph_core.GraphCore) ?u32 {
    const reader_token = rcu.readerEnter(graph) catch return null;
    defer rcu.readerExit(graph, reader_token);

    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;

    const cursor = &graph.repair_scan_cursor_tombstone;
    if (cursor.* >= node_count) cursor.* = 0;

    if (scanTombstoneRange(graph, cursor.*, node_count)) |node_index| {
        cursor.* = node_index + 1;
        return node_index;
    }
    if (scanTombstoneRange(graph, 0, cursor.*)) |node_index| {
        cursor.* = node_index + 1;
        return node_index;
    }

    return null;
}

fn nextRepairDebtNode(
    graph: *graph_core.GraphCore,
    processed_nodes: *const std.AutoHashMap(u32, void),
    allow_tombstone_scan: bool,
) ?u32 {
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
    if (allow_tombstone_scan) {
        if (findTombstoneDebtByScan(graph)) |node_index| {
            if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
        }
    }
    return null;
}

fn repairBudgetedWork(
    graph: *graph_core.GraphCore,
    max_nodes: usize,
    processed_nodes: *std.AutoHashMap(u32, void),
    allow_tombstone_scan: bool,
) !usize {
    var total_compacted: usize = 0;

    while (total_compacted < max_nodes) {
        const node_index = nextRepairDebtNode(graph, processed_nodes, allow_tombstone_scan) orelse break;
        try processed_nodes.put(node_index, {});

        if (try repairBothSides(graph, .{ .index = node_index })) total_compacted += 1;
    }

    return total_compacted;
}

fn flushTombstoneDebt(
    graph: *graph_core.GraphCore,
    max_nodes: usize,
    processed_nodes: *std.AutoHashMap(u32, void),
) !usize {
    var total_compacted: usize = 0;

    while (total_compacted < max_nodes) {
        const node_index = findTombstoneDebtByScan(graph) orelse break;
        if (!isEligibleRepairCandidate(graph, processed_nodes, node_index)) continue;
        try processed_nodes.put(node_index, {});

        if (try repairBothSides(graph, .{ .index = node_index })) total_compacted += 1;
    }

    return total_compacted;
}

/// Run up to `max_nodes` repair operations across the repair debt queue.
/// Each operation repairs at most one distinct node (both sides if needed).
/// Returns the number of nodes repaired.
pub fn repairBudgeted(graph: *graph_core.GraphCore, max_nodes: usize) !usize {
    if (graph.active_repairers.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        return error.ConcurrentMutation;
    }
    defer graph.active_repairers.store(0, .release);

    var processed_nodes = std.AutoHashMap(u32, void).init(graph.allocator);
    defer processed_nodes.deinit();

    const total_compacted = try repairBudgetedWork(graph, max_nodes, &processed_nodes, false);

    if (total_compacted > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }

    return total_compacted;
}

pub fn flushRepairs(graph: *graph_core.GraphCore) !types.RepairFlushSummary {
    if (graph.active_repairers.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        return error.ConcurrentMutation;
    }
    defer graph.active_repairers.store(0, .release);

    const node_count = graph.publishedNodeCount();
    if (node_count == 0) {
        return .{
            .repaired_nodes = 0,
            .pass_count = 0,
            .remaining_repair_fwd = 0,
            .remaining_repair_rev = 0,
            .remaining_structural_debt = false,
        };
    }

    var processed_nodes = std.AutoHashMap(u32, void).init(graph.allocator);
    defer processed_nodes.deinit();

    const repaired_flagged = try repairBudgetedWork(graph, node_count, &processed_nodes, false);
    const repaired_scanned = try flushTombstoneDebt(graph, node_count - repaired_flagged, &processed_nodes);
    const repaired_nodes = repaired_flagged + repaired_scanned;

    if (repaired_nodes > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }

    const remaining_repair_fwd = debt_mod.countNodesWithRepairFlag(graph, .fwd);
    const remaining_repair_rev = debt_mod.countNodesWithRepairFlag(graph, .rev);

    return .{
        .repaired_nodes = repaired_nodes,
        .pass_count = if (repaired_scanned > 0) 2 else 1,
        .remaining_repair_fwd = remaining_repair_fwd,
        .remaining_repair_rev = remaining_repair_rev,
        .remaining_structural_debt = remaining_repair_fwd > 0 or remaining_repair_rev > 0,
    };
}
