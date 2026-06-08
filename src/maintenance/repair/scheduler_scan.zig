//! Repair candidate selection and tombstone scanning.

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const debt_mod = @import("debt.zig");
const rebuild_mod = @import("rebuild.zig");

fn scanTombstoneRange(graph: *graph_core.GraphCore, start: u32, end: u32) ?u32 {
    var node_idx = start;
    while (node_idx < end) : (node_idx += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_idx)) continue;
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_idx }).publishedAdj();
        if (adjacency.block_count_fwd == 0) continue;
        if (rebuild_mod.hasAnyTombstone(graph, adjacency.first_block_fwd, adjacency.block_count_fwd, adjacency.group_count_fwd, adjacency.first_group_fwd, .fwd)) {
            return node_idx;
        }
    }
    return null;
}

/// Returns whether one node is live and has not already been processed in this pass.
pub fn isEligibleRepairCandidate(graph: *const graph_core.GraphCore, processed_nodes: *const std.AutoHashMap(u32, void), node_idx: u32) bool {
    if (processed_nodes.contains(node_idx)) return false;
    return node_validity.isNodeLiveIndex(graph, node_idx);
}

/// Scans for one live node whose forward side still contains tombstones.
pub fn findTombstoneDebtByScan(graph: *graph_core.GraphCore) ?u32 {
    const reader_token = rcu.readerEnter(graph) catch return null;
    defer rcu.readerExit(graph, reader_token);

    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;

    const cursor = &graph.repair_scan_cursor_tombstone;
    if (cursor.* >= node_count) cursor.* = 0;

    if (scanTombstoneRange(graph, cursor.*, node_count)) |node_idx| {
        cursor.* = node_idx + 1;
        return node_idx;
    }
    if (scanTombstoneRange(graph, 0, cursor.*)) |node_idx| {
        cursor.* = node_idx + 1;
        return node_idx;
    }

    return null;
}

/// Picks the next repair candidate from queues, flags, or optional tombstone scan.
pub fn nextRepairDebtNode(
    graph: *graph_core.GraphCore,
    processed_nodes: *const std.AutoHashMap(u32, void),
    allow_tombstone_scan: bool,
) ?u32 {
    if (debt_mod.popRepairDebtBestEffort(graph, .fwd)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.popRepairDebtBestEffort(graph, .rev)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .fwd)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .rev)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (allow_tombstone_scan) {
        if (findTombstoneDebtByScan(graph)) |node_idx| {
            if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
        }
    }
    return null;
}
