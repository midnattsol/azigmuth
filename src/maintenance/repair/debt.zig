//! Repair debt tracking — occupancy thresholds, queue management, and flag updates.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_bitmap = @import("../../core/node_bitmap.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const layout_debt = @import("../layout_debt.zig");
const rebuild_mod = @import("rebuild.zig");

fn repairCursor(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *u32 {
    return switch (side) {
        .fwd => &graph.repair_scan_cursor_fwd,
        .rev => &graph.repair_scan_cursor_rev,
    };
}

fn getRepairFlag(adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) bool {
    return switch (side) {
        .fwd => adj.flags.needs_repair_fwd,
        .rev => adj.flags.needs_repair_rev,
    };
}

fn setRepairFlag(adj: *types.NodeAdj, comptime side: adjacency.AdjSide, value: bool) void {
    switch (side) {
        .fwd => adj.flags.needs_repair_fwd = value,
        .rev => adj.flags.needs_repair_rev = value,
    }
}

fn repairQueue(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *std.ArrayList(u32) {
    return switch (side) {
        .fwd => &graph.repair_fwd,
        .rev => &graph.repair_rev,
    };
}

fn lockRepairQueue(graph: *graph_core.GraphCore) void {
    while (graph.repair_queue_lock.cmpxchgWeak(0, 1, .acq_rel, .acquire) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockRepairQueue(graph: *graph_core.GraphCore) void {
    graph.repair_queue_lock.store(0, .release);
}

fn repairQueuePages(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) []std.atomic.Value(usize) {
    return switch (side) {
        .fwd => graph.repair_queued_fwd_pages[0..],
        .rev => graph.repair_queued_rev_pages[0..],
    };
}

fn enqueueRepairDebtBestEffort(graph: *graph_core.GraphCore, node_index: u32, comptime side: adjacency.AdjSide) void {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);

    if (node_bitmap.testAndSetBit(graph, repairQueuePages(graph, side), node_index) catch true) return;
    repairQueue(graph, side).append(graph.allocator, node_index) catch {
        _ = node_bitmap.testAndClearBit(repairQueuePages(graph, side), node_index);
    };
}

pub fn popRepairDebtBestEffort(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);

    const queue = repairQueue(graph, side);
    while (queue.pop()) |node_index| {
        _ = node_bitmap.testAndClearBit(repairQueuePages(graph, side), node_index);
        return node_index;
    }
    return null;
}

fn nodeNeedsRepair(graph: *const graph_core.GraphCore, node_index: u32, comptime side: adjacency.AdjSide) bool {
    const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
    if (adj.flags.removed) return false;
    return switch (side) {
        .fwd => adj.flags.needs_repair_fwd,
        .rev => adj.flags.needs_repair_rev,
    };
}

pub fn queuedRepairCount(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) usize {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);
    return repairQueue(graph, side).items.len;
}

pub fn countNodesWithRepairFlag(graph: *const graph_core.GraphCore, comptime side: adjacency.AdjSide) usize {
    const node_count = graph.publishedNodeCount();
    var total: usize = 0;
    for (0..node_count) |node_index_usize| {
        const node_index: u32 = @intCast(node_index_usize);
        if (nodeNeedsRepair(graph, node_index, side)) total += 1;
    }
    return total;
}

pub fn findRepairDebtByFlag(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    const cursor = repairCursor(graph, side);
    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;
    if (cursor.* >= node_count) cursor.* = 0;

    var node_index = cursor.*;
    while (node_index < node_count) : (node_index += 1) {
        if (nodeNeedsRepair(graph, node_index, side)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }
    // Wrap: scan from 0 to cursor
    node_index = 0;
    while (node_index < cursor.*) : (node_index += 1) {
        if (nodeNeedsRepair(graph, node_index, side)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }
    return null;
}

/// Checks non-tail blocks reachable from `adj` (by reading block data
/// from the graph), sets or clears the `needs_repair` flag on `adj.flags`,
/// and pushes `node_index` onto the repair debt queue when the flag is set.
pub fn updateRepairDebt(
    graph: *graph_core.GraphCore,
    adj: *types.NodeAdj,
    node_index: u32,
    comptime side: adjacency.AdjSide,
) void {
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    const needs_repair = computeNeedsRepair(graph, adj, side);
    const previous_flag = getRepairFlag(adj, side);
    setRepairFlag(adj, side, needs_repair);
    if (!previous_flag and needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
}

pub fn updateRepairDebtAfterEdgeMutation(
    graph: *graph_core.GraphCore,
    adj: *types.NodeAdj,
    node_index: u32,
    comptime side: adjacency.AdjSide,
    previous_flag: bool,
) void {
    _ = graph;
    _ = node_index;
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    // Hot-path edge mutations keep repair debt sticky but do not rescan the
    // whole side. Exact recomputation belongs to explicit repair/validation.
    setRepairFlag(adj, side, previous_flag);
}

pub fn computeNeedsRepair(
    graph: *graph_core.GraphCore,
    adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) bool {
    const published_side = side_adj.sideAdjOfNode(adj.*, side);
    const report = layout_debt.analyzeSideLayout(graph, published_side, side) catch return true;

    const needs_repair = published_side.block_count > 0 and rebuild_mod.hasAnyTombstone(
        graph,
        published_side.first_block,
        published_side.block_count,
        published_side.group_count,
        published_side.first_group,
        side,
    );

    if (published_side.block_count <= 1) {
        return needs_repair;
    }

    if (published_side.group_count == 0) {
        return needs_repair or report.has_underfull_non_tail_block;
    }

    return needs_repair or
        report.has_underfull_non_tail_block or
        report.group_count_exceeded;
}

/// Recomputes repair debt for the currently published adjacency of one side and
/// stores the resulting flag back in `node.flags`.
pub fn updateRepairDebtSide(
    graph: *graph_core.GraphCore,
    node: *types.NodeBuffer,
    node_index: u32,
    comptime side: adjacency.AdjSide,
) void {
    var adj = node.publishedAdj();
    updateRepairDebt(graph, &adj, node_index, side);
    var expected = node.loadPublishedMeta();
    while (true) {
        var desired = expected;
        switch (side) {
            .fwd => desired.needs_repair_fwd = adj.flags.needs_repair_fwd,
            .rev => desired.needs_repair_rev = adj.flags.needs_repair_rev,
        }
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse break;
        expected = actual;
    }
}
