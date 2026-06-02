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
const node_validity = @import("node_validity.zig");

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

/// Copies one entry from `source_block[source_slot]` to `destination_block[destination_slot]`.
fn copyEdge(
    destination_block: anytype,
    destination_slot: u7,
    source_block: anytype,
    source_slot: u7,
    comptime side: adjacency.AdjSide,
) void {
    switch (side) {
        .fwd => destination_block.edges[destination_slot] = source_block.edges[source_slot],
        .rev => destination_block.sources[destination_slot] = source_block.sources[source_slot],
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
    if (adj.flags.removed) return false;
    return if (side == .fwd) adj.flags.needs_repair_fwd else adj.flags.needs_repair_rev;
}

fn findRepairDebtByFlag(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
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
    const flag = if (side == .fwd) &adj.flags.needs_repair_fwd else &adj.flags.needs_repair_rev;
    const block_count = if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
    const first_block = if (side == .fwd) adj.first_block_fwd else adj.first_block_rev;
    const group_count = if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
    const first_group = if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;

    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    var needs_repair = side == .fwd and block_count > 0 and hasAnyTombstone(graph, first_block, block_count, group_count, first_group, .fwd);

    if (block_count <= 1) {
        flag.* = needs_repair;
        if (needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
        return;
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
            counted_groups += 1;
            if (group.next == constants.END_OF_CHAIN) break;
            group_idx = group.next;
        }
        if (!needs_repair and counted_groups > constants.MAX_GROUPS_PER_NODE) {
            needs_repair = true;
        }
        if (!needs_repair and chain_is_contiguous) {
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

const Emit = struct {
    fn one(
        idx: u32,
        run_start_ptr: *u32,
        run_count_ptr: *u16,
    ) void {
        if (run_count_ptr.* > 0 and idx == run_start_ptr.* + run_count_ptr.*) {
            run_count_ptr.* += 1;
        } else {
            run_start_ptr.* = idx;
            run_count_ptr.* = 1;
        }
    }
    fn flush(
        graph_ptr: *graph_core.GraphCore,
        adj: *types.NodeAdj,
        comptime dir: adjacency.AdjSide,
        run_start_ptr: *u32,
        run_count_ptr: *u16,
        total_blocks_ptr: *u16,
        first_block_set_ptr: *bool,
        tail_group_ptr: *?u32,
    ) !void {
        if (run_count_ptr.* == 0) return;
        if (!first_block_set_ptr.*) {
            switch (dir) {
                .fwd => {
                    adj.first_block_fwd = run_start_ptr.*;
                    adj.block_count_fwd = run_count_ptr.*;
                },
                .rev => {
                    adj.first_block_rev = run_start_ptr.*;
                    adj.block_count_rev = run_count_ptr.*;
                },
            }
            first_block_set_ptr.* = true;
        } else if (tail_group_ptr.* == null and (switch (dir) {
            .fwd => adj.group_count_fwd,
            .rev => adj.group_count_rev,
        }) == 0) {
            const prefix_group = try page_ops.allocGroup(graph_ptr);
            const group = try page_ops.allocGroup(graph_ptr);
            const first_start: u32 = switch (dir) {
                .fwd => adj.first_block_fwd,
                .rev => adj.first_block_rev,
            };
            const first_cnt: u16 = switch (dir) {
                .fwd => adj.block_count_fwd,
                .rev => adj.block_count_rev,
            };
            page_ops.groupAt(graph_ptr, prefix_group).* = .{ .start = first_start, .count = first_cnt, .next = group };
            page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
            switch (dir) {
                .fwd => {
                    adj.first_group_fwd = prefix_group;
                    adj.group_count_fwd = 2;
                },
                .rev => {
                    adj.first_group_rev = prefix_group;
                    adj.group_count_rev = 2;
                },
            }
            tail_group_ptr.* = group;
        } else {
            const group = try page_ops.allocGroup(graph_ptr);
            page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
            page_ops.groupAt(graph_ptr, tail_group_ptr.*.?).next = group;
            tail_group_ptr.* = group;
            switch (dir) {
                .fwd => adj.group_count_fwd += 1,
                .rev => adj.group_count_rev += 1,
            }
        }
        total_blocks_ptr.* += run_count_ptr.*;
        run_count_ptr.* = 0;
    }
};

/// Rebuilds `staging_adj` from the published adjacency, replacing the two
/// old blocks (`left_idx` and `right_idx`) with `new_left`.  If `new_right`
/// is non-null (fill-and-shift case), both new blocks are inserted.
/// Detects contiguous runs — O(N) instead of O(N²).
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

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set: bool = false;
    var tail_group: ?u32 = null;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            if (block_idx == right_idx) continue;
            const new_idx: u32 = if (block_idx == left_idx) new_left else @intCast(block_idx);
            Emit.one(new_idx, &run_start, &run_count);
            if (block_idx == left_idx) {
                if (new_right) |nr| {
                    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                    Emit.one(nr, &run_start, &run_count);
                }
            }
        }
        try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
        switch (side) {
            .fwd => staging_adj.block_count_fwd = total_blocks,
            .rev => staging_adj.block_count_rev = total_blocks,
        }
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            if (block_idx == right_idx) continue;
            const idx: u32 = if (block_idx == left_idx) new_left else @intCast(block_idx);
            Emit.one(idx, &run_start, &run_count);
            if (block_idx == left_idx) {
                if (new_right) |nr| {
                    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                    Emit.one(nr, &run_start, &run_count);
                }
            }
        }
        if (group.next == constants.END_OF_CHAIN) break;
        group_idx = group.next;
    }
    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
    switch (side) {
        .fwd => staging_adj.block_count_fwd = total_blocks,
        .rev => staging_adj.block_count_rev = total_blocks,
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

fn claimNodeForPublish(node_buffer: *types.NodeBuffer) !void {
    try claimNodeAdjacency(node_buffer, .fwd);
    errdefer releaseNodeAdjacency(node_buffer, .fwd);
    try claimNodeAdjacency(node_buffer, .rev);
}

fn releaseNodeForPublish(node_buffer: *types.NodeBuffer) void {
    releaseNodeAdjacency(node_buffer, .rev);
    releaseNodeAdjacency(node_buffer, .fwd);
}

fn buildAdjacencyFromBlocks(
    staging_adj: *types.NodeAdj,
    graph: *graph_core.GraphCore,
    comptime side: adjacency.AdjSide,
    blocks: []const u32,
) !void {
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
    if (blocks.len == 0) return;

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set: bool = false;
    var tail_group: ?u32 = null;

    for (blocks) |block_idx| {
        if (run_count > 0 and block_idx == run_start + run_count) {
            run_count += 1;
        } else {
            // flush previous run using Emit.flush
            if (run_count > 0) {
                try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
            }
            run_start = block_idx;
            run_count = 1;
        }
    }
    if (run_count > 0) {
        try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
    }
    switch (side) {
        .fwd => staging_adj.block_count_fwd = total_blocks,
        .rev => staging_adj.block_count_rev = total_blocks,
    }
}

fn copyEdgeSingle(
    graph: *graph_core.GraphCore,
    source_block: anytype,
    source_slot: u7,
    destination_block_index: u32,
    destination_slot: u7,
    comptime side: adjacency.AdjSide,
) void {
    const destination_block = page_ops.edgeBlockAt(graph, destination_block_index, side);
    switch (side) {
        .fwd => destination_block.edges[destination_slot] = source_block.edges[source_slot],
        .rev => destination_block.sources[destination_slot] = source_block.sources[source_slot],
    }
    // Set mask incrementally — caller sets final mask
    destination_block.mask = constants.denseMask(destination_slot + 1);
}

fn edgePointsToRemoved(
    graph: *const graph_core.GraphCore,
    block: anytype,
    slot: u7,
    comptime side: adjacency.AdjSide,
) bool {
    const node_id = switch (side) {
        .fwd => block.edges[slot].destination,
        .rev => block.sources[slot],
    };
    if (node_id >= graph.publishedNodeCount()) return false;
    return page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj().flags.removed;
}

fn hasAnyTombstone(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    comptime side: adjacency.AdjSide,
) bool {
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (edgePointsToRemoved(graph, block, @intCast(slot), side)) return true;
            }
        }
    } else {
        var gidx = first_group;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), side)) return true;
                }
            }
            gidx = grp.next;
        }
    }
    return false;
}

fn retireAdjacencySide(
    graph: *graph_core.GraphCore,
    published_adj: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const first_block: u32 = if (side == .fwd) published_adj.first_block_fwd else published_adj.first_block_rev;
    const block_count: u16 = if (side == .fwd) published_adj.block_count_fwd else published_adj.block_count_rev;
    const group_count: u16 = if (side == .fwd) published_adj.group_count_fwd else published_adj.group_count_rev;
    const first_group: u32 = if (side == .fwd) published_adj.first_group_fwd else published_adj.first_group_rev;

    if (block_count == 0) return;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            try retireBlock(graph, @intCast(block_idx), side);
        }
        return;
    }

    var gidx = first_group;
    while (gidx != constants.END_OF_CHAIN) {
        const grp = page_ops.groupAtConst(graph, gidx);
        for (grp.start..grp.start + grp.count) |block_idx| {
            try retireBlock(graph, @intCast(block_idx), side);
        }
        const old_group = gidx;
        gidx = grp.next;
        rcu.retireGroup(graph, old_group);
    }
}

fn collectForwardTombstoneDestinations(
    graph: *const graph_core.GraphCore,
    published_adj: types.NodeAdj,
    destinations: *std.ArrayList(u32),
) !void {
    if (published_adj.block_count_fwd == 0) return;

    if (published_adj.group_count_fwd == 0) {
        for (published_adj.first_block_fwd..published_adj.first_block_fwd + published_adj.block_count_fwd) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                const destination = block.edges[slot].destination;
                var seen = false;
                for (destinations.items) |existing| {
                    if (existing == destination) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try destinations.append(graph.allocator, destination);
            }
        }
        return;
    }

    var gidx = published_adj.first_group_fwd;
    while (gidx != constants.END_OF_CHAIN) {
        const grp = page_ops.groupAtConst(graph, gidx);
        for (grp.start..grp.start + grp.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                const destination = block.edges[slot].destination;
                var seen = false;
                for (destinations.items) |existing| {
                    if (existing == destination) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try destinations.append(graph.allocator, destination);
            }
        }
        gidx = grp.next;
    }
}

const ForwardTombstoneCompaction = struct {
    live_after: usize,
    removed_count: usize,
};

fn rebuildForwardWithoutRemovedDestinations(
    graph: *graph_core.GraphCore,
    node_index: u32,
    node_mut: *types.NodeBuffer,
    published_adj: types.NodeAdj,
) !ForwardTombstoneCompaction {
    node_mut.copyPublishedToStaging();
    const staging_adj = node_mut.stagingAdj();

    var live_after: usize = 0;
    var removed_count: usize = 0;

    if (published_adj.group_count_fwd == 0) {
        for (published_adj.first_block_fwd..published_adj.first_block_fwd + published_adj.block_count_fwd) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) {
                    removed_count += 1;
                } else {
                    live_after += 1;
                }
            }
        }
    } else {
        var gidx = published_adj.first_group_fwd;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) {
                        removed_count += 1;
                    } else {
                        live_after += 1;
                    }
                }
            }
            gidx = grp.next;
        }
    }

    var new_blocks = try std.ArrayList(u32).initCapacity(graph.allocator, (live_after + 63) / 64);
    defer new_blocks.deinit(graph.allocator);

    var current_block: ?u32 = null;
    var current_live: u7 = 0;

    if (published_adj.group_count_fwd == 0) {
        for (published_adj.first_block_fwd..published_adj.first_block_fwd + published_adj.block_count_fwd) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                if (current_block == null or current_live == 64) {
                    current_block = try page_ops.allocBlock(graph, .fwd);
                    try new_blocks.append(graph.allocator, current_block.?);
                    current_live = 0;
                }
                copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, .fwd);
                current_live += 1;
            }
        }
    } else {
        var gidx = published_adj.first_group_fwd;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                    if (current_block == null or current_live == 64) {
                        current_block = try page_ops.allocBlock(graph, .fwd);
                        try new_blocks.append(graph.allocator, current_block.?);
                        current_live = 0;
                    }
                    copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, .fwd);
                    current_live += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (current_block) |block_idx| {
        page_ops.edgeBlockAt(graph, block_idx, .fwd).mask = constants.denseMask(current_live);
    }

    try buildAdjacencyFromBlocks(staging_adj, graph, .fwd, new_blocks.items);
    updateRepairDebt(graph, staging_adj, node_index, .fwd);
    node_mut.degree_fwd = if (live_after < constants.DEGREE_OVERFLOW) @intCast(live_after) else constants.DEGREE_OVERFLOW;

    return .{ .live_after = live_after, .removed_count = removed_count };
}

fn rebuildReverseWithoutSource(
    graph: *graph_core.GraphCore,
    destination_index: u32,
    destination_node: *types.NodeBuffer,
    published_adj: types.NodeAdj,
    source_index: u32,
) !void {
    destination_node.copyPublishedToStaging();
    const staging_adj = destination_node.stagingAdj();

    var live_after: usize = 0;
    var removed_matches: usize = 0;

    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) {
                    removed_matches += 1;
                } else {
                    live_after += 1;
                }
            }
        }
    } else {
        var gidx = published_adj.first_group_rev;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) {
                        removed_matches += 1;
                    } else {
                        live_after += 1;
                    }
                }
            }
            gidx = grp.next;
        }
    }

    if (removed_matches != 1) return error.CorruptGraph;

    var new_blocks = try std.ArrayList(u32).initCapacity(graph.allocator, (live_after + 63) / 64);
    defer new_blocks.deinit(graph.allocator);

    var current_block: ?u32 = null;
    var current_live: u7 = 0;

    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) continue;
                if (current_block == null or current_live == 64) {
                    current_block = try page_ops.allocBlock(graph, .rev);
                    try new_blocks.append(graph.allocator, current_block.?);
                    current_live = 0;
                }
                copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, .rev);
                current_live += 1;
            }
        }
    } else {
        var gidx = published_adj.first_group_rev;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) continue;
                    if (current_block == null or current_live == 64) {
                        current_block = try page_ops.allocBlock(graph, .rev);
                        try new_blocks.append(graph.allocator, current_block.?);
                        current_live = 0;
                    }
                    copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, .rev);
                    current_live += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (current_block) |block_idx| {
        page_ops.edgeBlockAt(graph, block_idx, .rev).mask = constants.denseMask(current_live);
    }

    try buildAdjacencyFromBlocks(staging_adj, graph, .rev, new_blocks.items);
    updateRepairDebt(graph, staging_adj, destination_index, .rev);
    if (published_adj.flags.removed) {
        destination_node.degree_rev = 0;
    } else {
        destination_node.degree_rev = if (live_after < constants.DEGREE_OVERFLOW) @intCast(live_after) else constants.DEGREE_OVERFLOW;
    }
}

const ReverseCleanupTarget = struct {
    node_buffer: *types.NodeBuffer,
    published_adj_before: types.NodeAdj,
};

fn repairForwardTombstonesWithReverseCleanup(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    node_mut: *types.NodeBuffer,
) !usize {
    const published_adj = node_mut.publishedAdj();
    if (published_adj.block_count_fwd == 0) return 0;

    var tombstone_destinations: std.ArrayList(u32) = .empty;
    defer tombstone_destinations.deinit(graph.allocator);
    try collectForwardTombstoneDestinations(graph, published_adj, &tombstone_destinations);
    if (tombstone_destinations.items.len == 0) return 0;

    var claimed_dest_nodes = try std.ArrayList(*types.NodeBuffer).initCapacity(graph.allocator, tombstone_destinations.items.len);
    defer {
        var remaining = claimed_dest_nodes.items.len;
        while (remaining > 0) {
            remaining -= 1;
            releaseNodeForPublish(claimed_dest_nodes.items[remaining]);
        }
        claimed_dest_nodes.deinit(graph.allocator);
    }

    var reverse_updates = try std.ArrayList(ReverseCleanupTarget).initCapacity(graph.allocator, tombstone_destinations.items.len);
    defer reverse_updates.deinit(graph.allocator);

    for (tombstone_destinations.items) |destination_index| {
        const destination_node = page_ops.nodeAt(graph, .{ .index = destination_index });
        try claimNodeForPublish(destination_node);
        claimed_dest_nodes.appendAssumeCapacity(destination_node);
    }

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    const source_adj_before = node_mut.publishedAdj();
    const source_result = try rebuildForwardWithoutRemovedDestinations(graph, node.index, node_mut, source_adj_before);

    for (tombstone_destinations.items, claimed_dest_nodes.items) |destination_index, destination_node| {
        const destination_adj_before = destination_node.publishedAdj();
        try rebuildReverseWithoutSource(graph, destination_index, destination_node, destination_adj_before, node.index);
        try reverse_updates.append(graph.allocator, .{
            .node_buffer = destination_node,
            .published_adj_before = destination_adj_before,
        });
    }

    for (reverse_updates.items) |update| {
        update.node_buffer.publishStagingAdj();
        try retireAdjacencySide(graph, update.published_adj_before, .rev);
    }

    node_mut.publishStagingAdj();
    try retireAdjacencySide(graph, source_adj_before, .fwd);

    _ = source_result;
    return 1;
}

fn repairNodeSideLimited(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    comptime side: adjacency.AdjSide,
    max_compactions: usize,
) !usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    if (max_compactions == 0) return 0;

    var node_mut = page_ops.nodeAt(graph, node);
    try claimNodeForPublish(node_mut);
    defer releaseNodeForPublish(node_mut);

    const published_adj = node_mut.publishedAdj();
    if (!node_validity.snapshotIsLive(published_adj)) return 0;

    if (side == .fwd) {
        const compacted_tombstones = try repairForwardTombstonesWithReverseCleanup(graph, node, node_mut);
        if (compacted_tombstones > 0) return compacted_tombstones;
    }

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    const node_adj = published_adj;
    const first_block: u32 = if (side == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    const block_count: u16 = if (side == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    const group_count: u16 = if (side == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    const first_group: u32 = if (side == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;

    if (block_count <= 1) {
        // Check for tombstoned edges — if the single block has edges to
        // removed nodes, we still need to compact.
        if (block_count == 1) {
            const b = page_ops.edgeBlockAtConst(graph, first_block, side);
            const live: u7 = @intCast(@popCount(b.mask));
            var has_tombstone = false;
            for (0..live) |slot| {
                if (edgePointsToRemoved(graph, b, @intCast(slot), side)) {
                    has_tombstone = true;
                    break;
                }
            }
            if (!has_tombstone) return 0;
        } else {
            return 0;
        }
    }

    // Single-pass compaction: collect live edges from all blocks, pack into
    // new blocks, publish once.  O(B) instead of O(B²).
    node_mut.copyPublishedToStaging();
    const staging_adj = node_mut.stagingAdj();

    var total_live: usize = 0;
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            total_live += @popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask);
        }
    } else {
        var gidx = first_group;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                total_live += @popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask);
            }
            gidx = grp.next;
        }
    }

    const new_block_count = (total_live + 63) / 64;

    // Skip compaction if the current layout already meets occupancy thresholds
    // (e.g. a node with a full non-tail block and a tail block).
    if (group_count == 0) {
        const tail_start = first_block + block_count - 1;
        var needs_repair = false;
        for (first_block..tail_start) |block_idx| {
            if (@popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask) < constants.MIN_OCCUPANCY) {
                needs_repair = true;
                break;
            }
        }
        if (!needs_repair and group_count <= constants.MAX_GROUPS_PER_NODE) {
            // Even if occupancy is fine, check for tombstoned edges.
            if (!hasAnyTombstone(graph, first_block, block_count, group_count, first_group, side)) {
                updateRepairDebt(graph, staging_adj, node.index, side);
                return 0;
            }
        }
    } else {
        var gidx = first_group;
        var needs_repair = false;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            const is_tail_group = grp.next == constants.END_OF_CHAIN;
            const end = if (is_tail_group) grp.start + grp.count - 1 else grp.start + grp.count;
            for (grp.start..end) |block_idx| {
                if (@popCount(page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side).mask) < constants.MIN_OCCUPANCY) {
                    needs_repair = true;
                    break;
                }
            }
            if (needs_repair) break;
            if (grp.next == constants.END_OF_CHAIN) break;
            gidx = grp.next;
        }
        if (!needs_repair and group_count <= constants.MAX_GROUPS_PER_NODE) {
            if (!hasAnyTombstone(graph, first_block, block_count, group_count, first_group, side)) {
                updateRepairDebt(graph, staging_adj, node.index, side);
                return 0;
            }
        }
    }

    var new_blocks = try std.ArrayList(u32).initCapacity(graph.allocator, new_block_count);
    defer new_blocks.deinit(graph.allocator);

    var current_block: ?u32 = null;
    var current_live: u7 = 0;

    // Iterate edges in sorted order, pack into new blocks
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                // Skip tombstones: edges to/from removed nodes.
                if (edgePointsToRemoved(graph, block, @intCast(slot), side)) {
                    total_live -= 1;
                    continue;
                }
                if (current_block == null or current_live == 64) {
                    current_block = try page_ops.allocBlock(graph, side);
                    try new_blocks.append(graph.allocator, current_block.?);
                    current_live = 0;
                }
                copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, side);
                current_live += 1;
            }
        }
    } else {
        var gidx = first_group;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), side)) {
                        total_live -= 1;
                        continue;
                    }
                    if (current_block == null or current_live == 64) {
                        current_block = try page_ops.allocBlock(graph, side);
                        try new_blocks.append(graph.allocator, current_block.?);
                        current_live = 0;
                    }
                    copyEdgeSingle(graph, block, @intCast(slot), current_block.?, current_live, side);
                    current_live += 1;
                }
            }
            gidx = grp.next;
        }
    }

    // Set mask on the last block
    if (current_block) |cb| {
        page_ops.edgeBlockAt(graph, cb, side).mask = constants.denseMask(current_live);
    }

    // Rebuild staging adjacency from new blocks
    try buildAdjacencyFromBlocks(staging_adj, graph, side, new_blocks.items);

    // Retire old blocks
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            try retireBlock(graph, @intCast(block_idx), side);
        }
    } else {
        var gidx = first_group;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                try retireBlock(graph, @intCast(block_idx), side);
            }
            const old_g = gidx;
            gidx = grp.next;
            rcu.retireGroup(graph, old_g);
        }
    }

    updateRepairDebt(graph, staging_adj, node.index, side);
    if (side == .fwd) {
        node_mut.degree_fwd = if (total_live < constants.DEGREE_OVERFLOW) @intCast(total_live) else constants.DEGREE_OVERFLOW;
    } else {
        node_mut.degree_rev = if (total_live < constants.DEGREE_OVERFLOW) @intCast(total_live) else constants.DEGREE_OVERFLOW;
    }
    node_mut.publishStagingAdj();
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
    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;

    const cursor = &graph.repair_scan_cursor_tombstone;
    if (cursor.* >= node_count) cursor.* = 0;

    var node_index = cursor.*;
    while (node_index < node_count) : (node_index += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_index)) continue;
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
        if (adj.block_count_fwd == 0) continue;
        if (hasAnyTombstone(graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, .fwd)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }

    node_index = 0;
    while (node_index < cursor.*) : (node_index += 1) {
        if (!node_validity.isNodeLiveIndex(graph, node_index)) continue;
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_index }).publishedAdj();
        if (adj.block_count_fwd == 0) continue;
        if (hasAnyTombstone(graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, .fwd)) {
            cursor.* = node_index + 1;
            return node_index;
        }
    }

    return null;
}

fn nextRepairDebtNode(graph: *graph_core.GraphCore, processed_nodes: []const u32) ?u32 {
    if (popRepairDebtBestEffort(graph, .fwd)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (popRepairDebtBestEffort(graph, .rev)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (findRepairDebtByFlag(graph, .fwd)) |node_index| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_index)) return node_index;
    }
    if (findRepairDebtByFlag(graph, .rev)) |node_index| {
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
