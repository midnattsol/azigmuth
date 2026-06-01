//! Local repair — compact adjacency blocks to restore occupancy thresholds.
//!
//! When mutations cause blocks to fall below the minimum occupancy threshold,
//! `repairNode` merges adjacent under-full blocks into a single packed block,
//! updating the node's adjacency metadata.  Repair is local: only the
//! affected node is touched, never the full graph.

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");

fn findMergeCandidate(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    comptime side: adjacency.AdjSide,
) ?struct { left_idx: u32, right_idx: u32 } {
    if (block_count <= 1) return null;

    if (group_count == 0) {
        const start = first_block;
        const end = start + block_count;
        for (start..end - 1) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                return .{ .left_idx = @as(u32, @intCast(block_idx)), .right_idx = @as(u32, @intCast(block_idx)) + 1 };
            }
        }
        return null;
    }

    var prev_idx: ?u32 = null;
    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        const group_start = group.start;
        const group_end = group_start + group.count;
        for (group_start..group_end) |block_idx| {
            // Check block_idx (left) with its right neighbor
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                if (@as(u32, @intCast(block_idx)) + 1 < group_end) {
                    return .{ .left_idx = @as(u32, @intCast(block_idx)), .right_idx = @as(u32, @intCast(block_idx)) + 1 };
                }
            }
            prev_idx = @intCast(block_idx);
        }
        // Cross-group boundary: last block of this group with first of next
        if (group.next != constants.END_OF_CHAIN) {
            const next_group = page_ops.groupAtConst(graph, group.next);
            if (prev_idx) |previous_block_idx| {
                const left_block = page_ops.edgeBlockAtConst(graph, previous_block_idx, side);
                if (@popCount(left_block.mask) < constants.MIN_OCCUPANCY) {
                    return .{ .left_idx = previous_block_idx, .right_idx = next_group.start };
                }
            }
        }
        group_idx = group.next;
    }
    return null;
}

/// Copies one entry from `src_block[src_slot]` to `destination_block[destination_slot]`.
fn copyEdge(
    destination_block: anytype,
    destination_slot: u7,
    src_block: anytype,
    src_slot: u7,
    comptime side: adjacency.AdjSide,
) void {
    switch (side) {
        .fwd => destination_block.edges[destination_slot] = src_block.edges[src_slot],
        .rev => destination_block.sources[destination_slot] = src_block.sources[src_slot],
    }
}

/// Reads the sort key at `block[slot]` — `destination` for forward, the `u32` value itself for reverse.
fn readKey(
    block: anytype,
    slot: u7,
    comptime side: adjacency.AdjSide,
) u32 {
    return switch (side) {
        .fwd => block.edges[slot].destination,
        .rev => block.sources[slot],
    };
}

/// Retires one block in the given direction.
fn retireBlock(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) !void {
    switch (side) {
        .fwd => try rcu.retireBlockFwd(graph, block_idx),
        .rev => try rcu.retireBlockRev(graph, block_idx),
    }
}

/// Merges two adjacent blocks (left_idx and right_idx) into one or two blocks.
/// Updates `staging_adj` to replace the old blocks with the new ones.
/// Retires the old blocks via RCU.
fn mergeBlocks(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    left_idx: u32,
    right_idx: u32,
    comptime side: adjacency.AdjSide,
) !void {
    const left_block = page_ops.edgeBlockAtConst(graph, left_idx, side);
    const right_block = page_ops.edgeBlockAtConst(graph, right_idx, side);
    const left_edge_count: u7 = @intCast(@popCount(left_block.mask));
    const right_edge_count: u7 = @intCast(@popCount(right_block.mask));
    const total: u8 = @as(u8, left_edge_count) + @as(u8, right_edge_count);

    if (total <= 64) {
        // ── Single-block merge ──
        const merged = try page_ops.allocBlock(graph, side);
        errdefer switch (side) {
            .fwd => graph.free_blocks_fwd.append(graph.allocator, merged) catch {},
            .rev => graph.free_blocks_rev.append(graph.allocator, merged) catch {},
        };
        const merged_block = page_ops.edgeBlockAt(graph, merged, side);

        // Merge sorted arrays into merged_block
        var left_pos: u7 = 0;
        var right_pos: u7 = 0;
        var destination_pos: u7 = 0;
        while (left_pos < left_edge_count and right_pos < right_edge_count) : (destination_pos += 1) {
            const left_key: u32 = readKey(left_block, left_pos, side);
            const right_key: u32 = readKey(right_block, right_pos, side);
            if (left_key < right_key) {
                copyEdge(merged_block, destination_pos, left_block, left_pos, side);
                left_pos += 1;
            } else {
                copyEdge(merged_block, destination_pos, right_block, right_pos, side);
                right_pos += 1;
            }
        }
        while (left_pos < left_edge_count) : ({
            left_pos += 1;
            destination_pos += 1;
        }) {
            copyEdge(merged_block, destination_pos, left_block, left_pos, side);
        }
        while (right_pos < right_edge_count) : ({
            right_pos += 1;
            destination_pos += 1;
        }) {
            copyEdge(merged_block, destination_pos, right_block, right_pos, side);
        }
        if (total == 64) {
            merged_block.mask = constants.FULL_BLOCK_MASK;
        } else {
            merged_block.mask = constants.denseMask(@intCast(total));
        }

        // Rebuild staging adjacency with merged block replacing the pair
        try rebuildStagingAdjAfterMerge(graph, staging_adj, first_block, block_count, group_count, first_group, left_idx, right_idx, merged, null, side);
        try retireBlock(graph, left_idx, side);
        try retireBlock(graph, right_idx, side);
    } else {
        // ── Fill-and-shift merge ──
        const new_left = try page_ops.allocBlock(graph, side);
        errdefer switch (side) {
            .fwd => graph.free_blocks_fwd.append(graph.allocator, new_left) catch {},
            .rev => graph.free_blocks_rev.append(graph.allocator, new_left) catch {},
        };
        const new_right = try page_ops.allocBlock(graph, side);
        errdefer switch (side) {
            .fwd => graph.free_blocks_fwd.append(graph.allocator, new_right) catch {},
            .rev => graph.free_blocks_rev.append(graph.allocator, new_right) catch {},
        };
        const new_left_block = page_ops.edgeBlockAt(graph, new_left, side);
        const new_right_block = page_ops.edgeBlockAt(graph, new_right, side);

        // Copy left completely
        for (0..left_edge_count) |edge_index| {
            copyEdge(new_left_block, @intCast(edge_index), left_block, @intCast(edge_index), side);
        }
        // Fill left to 64 from right
        const fill_count: u7 = @intCast(64 - left_edge_count);
        for (0..fill_count) |edge_index| {
            copyEdge(new_left_block, @as(u7, @intCast(left_edge_count + edge_index)), right_block, @intCast(edge_index), side);
        }
        new_left_block.mask = constants.FULL_BLOCK_MASK;

        // Remaining right edges go to new_right
        const remaining: u7 = right_edge_count - fill_count;
        for (0..remaining) |edge_index| {
            copyEdge(new_right_block, @intCast(edge_index), right_block, @as(u7, @intCast(fill_count + edge_index)), side);
        }
        if (remaining == 64) {
            new_right_block.mask = constants.FULL_BLOCK_MASK;
        } else {
            new_right_block.mask = constants.denseMask(@intCast(remaining));
        }

        // Rebuild staging adjacency with two new blocks replacing the pair
        try rebuildStagingAdjAfterMerge(graph, staging_adj, first_block, block_count, group_count, first_group, left_idx, right_idx, new_left, new_right, side);
        try retireBlock(graph, left_idx, side);
        try retireBlock(graph, right_idx, side);
    }
}

fn repairQueue(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *std.ArrayList(u32) {
    return if (side == .fwd) &graph.repair_fwd else &graph.repair_rev;
}

fn enqueueRepairDebtBestEffort(graph: *graph_core.GraphCore, node_index: u32, comptime side: adjacency.AdjSide) void {
    // No locks here: per RFC direction, concurrent writers must not serialize
    // on a global repair queue. The published needs_repair flag is the source
    // of truth under concurrency; this ArrayList is only a single-writer fast
    // path and debug view.
    if (graph.active_writers.load(.monotonic) > 1) return;
    const queue = repairQueue(graph, side);
    for (queue.items) |existing| {
        if (existing == node_index) return;
    }
    queue.append(graph.allocator, node_index) catch {};
}

fn popRepairDebtBestEffort(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    if (graph.active_writers.load(.monotonic) > 1) return null;
    return repairQueue(graph, side).pop();
}

fn nodeNeedsRepair(graph: *const graph_core.GraphCore, node_index: u32, comptime side: adjacency.AdjSide) bool {
    const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
    return if (side == .fwd) adj.flags.needs_repair_fwd else adj.flags.needs_repair_rev;
}

fn findRepairDebtByFlag(graph: *const graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    var node_index: u32 = 0;
    while (node_index < graph.node_count) : (node_index += 1) {
        if (nodeNeedsRepair(graph, node_index, side)) return node_index;
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
    const flag = if (side == .fwd) &adj.flags.needs_repair_fwd else &adj.flags.needs_repair_rev;
    const block_count = if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
    const first_block = if (side == .fwd) adj.first_block_fwd else adj.first_block_rev;
    const group_count = if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
    const first_group = if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;

    if (block_count <= 1) {
        flag.* = false;
        return;
    }

    var needs_repair = false;

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
        while (group_idx != constants.END_OF_CHAIN) {
            const group = page_ops.groupAtConst(graph, group_idx);
            const is_last_group = group.next == constants.END_OF_CHAIN;
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
            counted_groups += 1;
            if (group.next == constants.END_OF_CHAIN) {
                counted_groups += 1;
                break;
            }
            group_idx = group.next;
        }
        if (!needs_repair and counted_groups > constants.MAX_GROUPS_PER_NODE) {
            needs_repair = true;
        }
    }

    flag.* = needs_repair;
    if (needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
}

/// Appends one block to the staging adjacency, handling the
/// first-block-special-case vs appending-to-group boundary.
fn appendOneBlock(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    block_index: u32,
    comptime side: adjacency.AdjSide,
) !void {
    switch (side) {
        .fwd => {
            if (staging_adj.block_count_fwd == 0) {
                staging_adj.first_block_fwd = block_index;
                staging_adj.block_count_fwd = 1;
            } else {
                try adjacency.appendGroupToAdj(graph, staging_adj, block_index, .fwd);
                staging_adj.block_count_fwd += 1;
            }
        },
        .rev => {
            if (staging_adj.block_count_rev == 0) {
                staging_adj.first_block_rev = block_index;
                staging_adj.block_count_rev = 1;
            } else {
                try adjacency.appendGroupToAdj(graph, staging_adj, block_index, .rev);
                staging_adj.block_count_rev += 1;
            }
        },
    }
}

/// Rebuilds `staging_adj` from the published adjacency, replacing the two
/// old blocks (`left_idx` and `right_idx`) with `new_left`.  If `new_right`
/// is non-null (fill-and-shift case), both new blocks are inserted.
/// Blocks other than the ones being replaced are shared directly — they are
/// immutable under RCU and safe to reuse.
fn rebuildStagingAdjAfterMerge(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    left_idx: u32,
    right_idx: u32,
    new_left: u32,
    new_right: ?u32,
    comptime side: adjacency.AdjSide,
) !void {
    // Zero the side-specific fields
    switch (side) {
        .fwd => {
            staging_adj.first_block_fwd = 0;
            staging_adj.block_count_fwd = 0;
            staging_adj.group_count_fwd = 0;
            staging_adj.first_group_fwd = 0;
        },
        .rev => {
            staging_adj.first_block_rev = 0;
            staging_adj.block_count_rev = 0;
            staging_adj.group_count_rev = 0;
            staging_adj.first_group_rev = 0;
        },
    }

    if (block_count == 0) return;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            if (block_idx == right_idx) continue;
            const new_idx: u32 = if (block_idx == left_idx) new_left else @intCast(block_idx);
            try appendOneBlock(graph, staging_adj, new_idx, side);
            if (block_idx == left_idx) {
                if (new_right) |nr| {
                    try appendOneBlock(graph, staging_adj, nr, side);
                }
            }
        }
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            if (block_idx == right_idx) continue;
            const new_idx: u32 = if (block_idx == left_idx) new_left else @intCast(block_idx);
            try appendOneBlock(graph, staging_adj, new_idx, side);
            if (block_idx == left_idx) {
                if (new_right) |nr| {
                    try appendOneBlock(graph, staging_adj, nr, side);
                }
            }
        }
        if (group.next == constants.END_OF_CHAIN) break;
        group_idx = group.next;
    }
}

const WriterGuard = struct {
    graph: *graph_core.GraphCore,
    active: bool = true,

    fn end(self: *WriterGuard) void {
        if (!self.active) return;
        _ = self.graph.active_writers.fetchSub(1, .acq_rel);
        self.active = false;
    }
};

fn beginWriter(graph: *graph_core.GraphCore) WriterGuard {
    const previous_writers = graph.active_writers.fetchAdd(1, .acq_rel);
    if (previous_writers > 0) graph.debug_retired_enabled.store(false, .release);
    return .{ .graph = graph };
}

fn claimNodeAdjacency(node_buffer: *types.NodeBuffer, comptime side: adjacency.AdjSide) !void {
    const claim = if (side == .fwd) &node_buffer.fwd_claim else &node_buffer.rev_claim;
    if (claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
}

fn releaseNodeAdjacency(node_buffer: *types.NodeBuffer, comptime side: adjacency.AdjSide) void {
    const claim = if (side == .fwd) &node_buffer.fwd_claim else &node_buffer.rev_claim;
    claim.store(0, .release);
}

fn repairNodeSideLimited(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !usize {
    if (node.index >= graph.node_count) return error.InvalidNode;

    var node_mut = page_ops.nodeAt(graph, node);
    try claimNodeAdjacency(node_mut, side);
    defer releaseNodeAdjacency(node_mut, side);

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    var compacted: usize = 0;
    const node_adj = node_mut.publishedAdj();
    var first_block: u32 = if (side == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    var block_count: u16 = if (side == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    var group_count: u16 = if (side == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    var first_group: u32 = if (side == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;

    if (block_count <= 1 or max_compactions == 0) return compacted;

    node_mut.copyPublishedToStaging();
    const staging_adj = node_mut.stagingAdj();

    while (compacted < max_compactions) {
        const pair = findMergeCandidate(graph, first_block, block_count, group_count, first_group, side) orelse break;
        try mergeBlocks(graph, staging_adj, first_block, block_count, group_count, first_group, pair.left_idx, pair.right_idx, side);
        compacted += 1;
        // Reload layout from staging_adj after merge
        first_block = if (side == .fwd) staging_adj.first_block_fwd else staging_adj.first_block_rev;
        block_count = if (side == .fwd) staging_adj.block_count_fwd else staging_adj.block_count_rev;
        group_count = if (side == .fwd) staging_adj.group_count_fwd else staging_adj.group_count_rev;
        first_group = if (side == .fwd) staging_adj.first_group_fwd else staging_adj.first_group_rev;
    }

    if (compacted > 0) {
        // Re-check occupancy after repair — clear or re-set the repair flag.
        updateRepairDebt(graph, staging_adj, node.index, side);
        node_mut.publishStagingAdj();
    }

    return compacted;
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
    if (node.index >= graph.node_count) return error.InvalidNode;

    const compacted_fwd = try repairNodeSide(graph, node, .fwd);
    const compacted_rev = try repairNodeSide(graph, node, .rev);
    if (compacted_fwd + compacted_rev > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }
}

/// Run up to `max_steps` repair operations across the repair debt queue.
/// Returns the number of block-pair compactions performed.
pub fn repairBudgeted(graph: *graph_core.GraphCore, max_steps: usize) !usize {
    var total_compacted: usize = 0;

    // Process forward repair debt. Prefer the single-writer queue when it is
    // available, but fall back to scanning published flags so concurrent
    // writers do not need a global queue lock.
    while (total_compacted < max_steps) {
        const node_index = popRepairDebtBestEffort(graph, .fwd) orelse findRepairDebtByFlag(graph, .fwd) orelse break;
        const remaining_steps = max_steps - total_compacted;
        const compacted = try repairNodeSideLimited(graph, .{ .index = node_index }, .fwd, remaining_steps);
        total_compacted += compacted;
        if (compacted == 0) break;
    }

    // Process reverse repair debt.
    while (total_compacted < max_steps) {
        const node_index = popRepairDebtBestEffort(graph, .rev) orelse findRepairDebtByFlag(graph, .rev) orelse break;
        const remaining_steps = max_steps - total_compacted;
        const compacted = try repairNodeSideLimited(graph, .{ .index = node_index }, .rev, remaining_steps);
        total_compacted += compacted;
        if (compacted == 0) break;
    }

    if (total_compacted > 0) {
        rcu.bumpEpoch(graph);
        rcu.reclaimRetired(graph);
    }

    return total_compacted;
}
