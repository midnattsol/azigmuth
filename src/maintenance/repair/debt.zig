//! Repair debt tracking — occupancy thresholds, queue management, and flag updates.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_bitmap = @import("../../core/node_bitmap.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rebuild_mod = @import("rebuild.zig");

fn repairQueue(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *std.ArrayList(u32) {
    return if (side == .fwd) &graph.repair_fwd else &graph.repair_rev;
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
    return if (side == .fwd) graph.repair_queued_fwd_pages[0..] else graph.repair_queued_rev_pages[0..];
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
    return if (side == .fwd) adj.flags.needs_repair_fwd else adj.flags.needs_repair_rev;
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
    const cursor: *u32 = if (side == .fwd) &graph.repair_scan_cursor_fwd else &graph.repair_scan_cursor_rev;
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
    const flag = if (side == .fwd) &adj.flags.needs_repair_fwd else &adj.flags.needs_repair_rev;
    const previous_flag = flag.*;
    flag.* = needs_repair;
    if (!previous_flag and needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
}

fn mutationShapeNeedsRepair(
    graph: *const graph_core.GraphCore,
    adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) bool {
    const block_count = if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
    const group_count = if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
    const first_group = if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;

    if (block_count <= 1) return group_count > 0;
    if (group_count == 0) return false;

    adjacency.validateNodeAdjLayout(graph, adj.*, side) catch return true;
    if (group_count > constants.MAX_GROUPS_PER_NODE) return true;

    var group_idx = first_group;
    var visited: u16 = 0;
    var previous_group_end: ?u32 = null;
    var chain_is_contiguous = true;
    while (visited < group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_idx);
        const is_last_group = group.next == constants.END_OF_CHAIN;
        if (previous_group_end) |expected_start| {
            if (group.start != expected_start) chain_is_contiguous = false;
        }
        previous_group_end = group.start + group.count;
        if (!is_last_group and group.count < 4) return true;
        group_idx = group.next;
    }

    return chain_is_contiguous;
}

pub fn updateRepairDebtAfterEdgeMutation(
    graph: *graph_core.GraphCore,
    adj: *types.NodeAdj,
    node_index: u32,
    comptime side: adjacency.AdjSide,
    previous_flag: bool,
) void {
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    const flag = if (side == .fwd) &adj.flags.needs_repair_fwd else &adj.flags.needs_repair_rev;
    const needs_repair = previous_flag or mutationShapeNeedsRepair(graph, adj, side);
    flag.* = needs_repair;
    if (!previous_flag and needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
}

pub fn computeNeedsRepair(
    graph: *graph_core.GraphCore,
    adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) bool {
    const block_count = if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
    const first_block = if (side == .fwd) adj.first_block_fwd else adj.first_block_rev;
    const group_count = if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
    const first_group = if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;

    if (group_count > 0) {
        adjacency.validateNodeAdjLayout(graph, adj.*, side) catch return true;
    }

    var needs_repair = side == .fwd and block_count > 0 and rebuild_mod.hasAnyTombstone(graph, first_block, block_count, group_count, first_group, .fwd);

    if (block_count <= 1) {
        // A grouped single-block adjacency is always a canonicalization
        // opportunity regardless of tombstones or occupancy.
        if (group_count > 0) needs_repair = true;
        return needs_repair;
    }

    if (group_count == 0) {
        // Contiguous blocks — skip the tail block (last block).
        const end = first_block + block_count - 1;
        for (first_block..end) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                needs_repair = true;
                break;
            }
        }
    } else {
        var group_idx = first_group;
        var counted_groups: u16 = 0;
        var previous_group_end: ?u32 = null;
        var chain_is_contiguous = true;
        while (group_idx != constants.END_OF_CHAIN) {
            counted_groups += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            const is_last_group = group.next == constants.END_OF_CHAIN;
            if (previous_group_end) |expected_start| {
                if (group.start != expected_start) chain_is_contiguous = false;
            }
            previous_group_end = group.start + group.count;
            if (!is_last_group and group.count < 4) {
                needs_repair = true;
                break;
            }
            // For the last group, skip the tail block.
            const end = if (is_last_group) group.start + group.count - 1 else group.start + group.count;
            for (group.start..end) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
                if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                    needs_repair = true;
                    break;
                }
            }
            if (needs_repair) break;
            group_idx = group.next;
        }
        if (!needs_repair and counted_groups > constants.MAX_GROUPS_PER_NODE) {
            needs_repair = true;
        }
        if (!needs_repair and chain_is_contiguous) {
            needs_repair = true;
        }
    }

    return needs_repair;
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
        if (side == .fwd) {
            desired.needs_repair_fwd = adj.flags.needs_repair_fwd;
        } else {
            desired.needs_repair_rev = adj.flags.needs_repair_rev;
        }
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse break;
        expected = actual;
    }
}
