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
const mutation_common = @import("mutation/common.zig");

fn publishBothAdj(node: *types.NodeBuffer, adj: types.NodeAdj) void {
    const meta = node.loadPublishedMeta();
    node.stagingFwd(meta).* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = mutation_common.publishStagedBoth(node, meta, adj.flags);
}

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
    var visited: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return null;
        if (visited >= group_count or visited >= graph.group_count) return null;
        visited += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        const group_start = group.start;
        const group_end = group_start + group.count;
        for (group_start..group_end) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                if (@as(u32, @intCast(block_idx)) + 1 < group_end) {
                    return .{ .left_idx = @as(u32, @intCast(block_idx)), .right_idx = @as(u32, @intCast(block_idx)) + 1 };
                }
            }
            prev_idx = @intCast(block_idx);
        }
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
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    const needs_repair = computeNeedsRepair(graph, adj, side);
    const flag = if (side == .fwd) &adj.flags.needs_repair_fwd else &adj.flags.needs_repair_rev;
    flag.* = needs_repair;
    if (needs_repair) enqueueRepairDebtBestEffort(graph, node_index, side);
}

fn computeNeedsRepair(
    graph: *graph_core.GraphCore,
    adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) bool {
    const block_count = if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
    const first_block = if (side == .fwd) adj.first_block_fwd else adj.first_block_rev;
    const group_count = if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
    const first_group = if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;

    var needs_repair = side == .fwd and block_count > 0 and hasAnyTombstone(graph, first_block, block_count, group_count, first_group, .fwd);

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
            if (group_idx >= graph.group_count) return true;
            if (counted_groups >= group_count or counted_groups >= graph.group_count) return true;
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
        const desired = expected.withFlags(adj.flags);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse break;
        expected = actual;
    }
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
        allocs_optional: ?*mutation_common.PrePublishAllocations,
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
            const prefix_group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
            const group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
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
            const group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
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
                    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, null);
                    Emit.one(nr, &run_start, &run_count);
                }
            }
        }
        try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, null);
        switch (side) {
            .fwd => staging_adj.block_count_fwd = total_blocks,
            .rev => staging_adj.block_count_rev = total_blocks,
        }
        return;
    }

    var group_idx = first_group;
    var visited_groups_build: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (visited_groups_build >= group_count or visited_groups_build >= graph.group_count) return error.CorruptGraph;
        visited_groups_build += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            if (block_idx == right_idx) continue;
            const idx: u32 = if (block_idx == left_idx) new_left else @intCast(block_idx);
            Emit.one(idx, &run_start, &run_count);
            if (block_idx == left_idx) {
                if (new_right) |nr| {
                    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, null);
                    Emit.one(nr, &run_start, &run_count);
                }
            }
        }
        if (group.next == constants.END_OF_CHAIN) break;
        group_idx = group.next;
    }
    try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, null);
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
    allocs: ?*mutation_common.PrePublishAllocations,
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
                try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
            }
            run_start = block_idx;
            run_count = 1;
        }
    }
    if (run_count > 0) {
        try Emit.flush(graph, staging_adj, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
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
        var group_idx = first_group;
        var visited: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            if (group_idx >= graph.group_count) return false;
            if (visited >= group_count or visited >= graph.group_count) return false;
            visited += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), side)) return true;
                }
            }
            group_idx = group.next;
        }
    }
    return false;
}

// ── k-way merge rebuild helpers ───────────────────────────────────────

const BlockIter = struct {
    block_idx: u32,
    live: u7,
    pos: u7,
};

const SortedRebuildResult = struct {
    new_blocks: std.ArrayList(u32),
    live_after: usize,
};

pub fn sortedRebuildForward(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    var live_after: usize = 0;
    var max_iters: usize = 0;

    // Count live and determine how many iterators we need.
    if (group_count == 0) {
        max_iters = block_count;
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) live_after += 1;
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups >= group_count or visited_groups >= graph.group_count) return error.CorruptGraph;
            visited_groups += 1;
            const grp = page_ops.groupAtConst(graph, gidx);
            max_iters += grp.count;
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) live_after += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    const out_blocks = (live_after + 63) / 64;
    var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_blocks);
    errdefer {
        for (new_blocks.items) |block| page_ops.freeBlock(graph, block, .fwd);
        new_blocks.deinit(allocator);
    }

    var iters = try std.ArrayList(BlockIter).initCapacity(allocator, @max(1, max_iters));
    defer iters.deinit(allocator);

    // Build iterator list
    if (group_count == 0) {
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
            const live: u7 = @intCast(@popCount(block.mask));
            var pos: u7 = 0;
            while (pos < live) : (pos += 1) {
                if (!edgePointsToRemoved(graph, block, pos, .fwd)) break;
            }
            if (pos < live) {
                try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups2: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups2 >= group_count or visited_groups2 >= graph.group_count) return error.CorruptGraph;
            visited_groups2 += 1;
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
                const live: u7 = @intCast(@popCount(block.mask));
                var pos: u7 = 0;
                while (pos < live) : (pos += 1) {
                    if (!edgePointsToRemoved(graph, block, pos, .fwd)) break;
                }
                if (pos < live) {
                    try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        // Find iterator with minimum key
        var min_idx: usize = 0;
        var min_key: u32 = std.math.maxInt(u32);
        for (iters.items, 0..) |iter, idx| {
            const block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .fwd);
            const key = block.edges[iter.pos].destination;
            if (key < min_key) { min_key = key; min_idx = idx; }
        }

        const iter_ref = &iters.items[min_idx];
        const block = page_ops.edgeBlockAtConst(graph, iter_ref.block_idx, .fwd);
        const edge = block.edges[iter_ref.pos];

        if (out_block == null or out_slot == 64) {
            out_block = try page_ops.allocBlock(graph, .fwd);
            new_blocks.appendAssumeCapacity(out_block.?);
            out_slot = 0;
        }

        const dst_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
        dst_block.edges[out_slot] = edge;
        out_slot += 1;
        if (out_slot == 64) {
            const full_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
            full_block.mask = constants.FULL_BLOCK_MASK;
        }

        // Advance iterator, skip tombstones
        iter_ref.pos += 1;
        while (iter_ref.pos < iter_ref.live) : (iter_ref.pos += 1) {
            if (!edgePointsToRemoved(graph, block, iter_ref.pos, .fwd)) break;
        }
        if (iter_ref.pos >= iter_ref.live) {
            _ = iters.swapRemove(min_idx);
        }
    }

    if (out_block) |ob| {
        page_ops.edgeBlockAt(graph, ob, .fwd).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = live_after };
}

pub fn sortedRebuildReverse(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    skip_source_index: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    var live_after: usize = 0;
    var max_iters: usize = 0;

    if (group_count == 0) {
        max_iters = block_count;
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (skip_source_index != null and block.sources[slot] == skip_source_index.?) continue;
                if (edgePointsToRemoved(graph, block, @intCast(slot), .rev)) continue;
                live_after += 1;
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups_rev1: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups_rev1 >= group_count or visited_groups_rev1 >= graph.group_count) return error.CorruptGraph;
            visited_groups_rev1 += 1;
            const grp = page_ops.groupAtConst(graph, gidx);
            max_iters += grp.count;
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (skip_source_index != null and block.sources[slot] == skip_source_index.?) continue;
                    if (edgePointsToRemoved(graph, block, @intCast(slot), .rev)) continue;
                    live_after += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    const out_blocks = (live_after + 63) / 64;
    var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_blocks);
    errdefer {
        for (new_blocks.items) |block| page_ops.freeBlock(graph, block, .rev);
        new_blocks.deinit(allocator);
    }

    var iters = try std.ArrayList(BlockIter).initCapacity(allocator, @max(1, max_iters));
    defer iters.deinit(allocator);

    if (group_count == 0) {
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
            const live: u7 = @intCast(@popCount(block.mask));
            var pos: u7 = 0;
            while (pos < live) : (pos += 1) {
                if (skip_source_index != null and block.sources[pos] == skip_source_index.?) continue;
                if (edgePointsToRemoved(graph, block, pos, .rev)) continue;
                break;
            }
            if (pos < live) {
                try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups_rev2: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups_rev2 >= group_count or visited_groups_rev2 >= graph.group_count) return error.CorruptGraph;
            visited_groups_rev2 += 1;
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
                const live: u7 = @intCast(@popCount(block.mask));
                var pos: u7 = 0;
                while (pos < live) : (pos += 1) {
                    if (skip_source_index != null and block.sources[pos] == skip_source_index.?) continue;
                    if (edgePointsToRemoved(graph, block, pos, .rev)) continue;
                    break;
                }
                if (pos < live) {
                    try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        var min_idx: usize = 0;
        var min_key: u32 = std.math.maxInt(u32);
        for (iters.items, 0..) |iter, idx| {
            const block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .rev);
            const key = block.sources[iter.pos];
            if (key < min_key) { min_key = key; min_idx = idx; }
        }

        const iter_ref = &iters.items[min_idx];
        const block = page_ops.edgeBlockAtConst(graph, iter_ref.block_idx, .rev);
        const source_id = block.sources[iter_ref.pos];

        if (out_block == null or out_slot == 64) {
            out_block = try page_ops.allocBlock(graph, .rev);
            new_blocks.appendAssumeCapacity(out_block.?);
            out_slot = 0;
        }

        const dst_block = page_ops.edgeBlockAt(graph, out_block.?, .rev);
        dst_block.sources[out_slot] = source_id;
        out_slot += 1;
        if (out_slot == 64) {
            const full_block = page_ops.edgeBlockAt(graph, out_block.?, .rev);
            full_block.mask = constants.FULL_BLOCK_MASK;
        }

        iter_ref.pos += 1;
        while (iter_ref.pos < iter_ref.live) : (iter_ref.pos += 1) {
            if (skip_source_index != null and block.sources[iter_ref.pos] == skip_source_index.?) continue;
            if (edgePointsToRemoved(graph, block, iter_ref.pos, .rev)) continue;
            break;
        }
        if (iter_ref.pos >= iter_ref.live) {
            _ = iters.swapRemove(min_idx);
        }
    }

    if (out_block) |ob| {
        page_ops.edgeBlockAt(graph, ob, .rev).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = live_after };
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

    var group_idx = first_group;
    var retired_visited: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (retired_visited >= group_count or retired_visited >= graph.group_count) return error.CorruptGraph;
        retired_visited += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            try retireBlock(graph, @intCast(block_idx), side);
        }
        const old_grouproup = group_idx;
        group_idx = group.next;
        rcu.retireGroup(graph, old_grouproup);
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

    var group_idx = published_adj.first_group_fwd;
    var visited_dests: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (visited_dests >= published_adj.group_count_fwd or visited_dests >= graph.group_count) return error.CorruptGraph;
        visited_dests += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
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
        group_idx = group.next;
    }
}

const ForwardTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
    removed_count: usize,
};

const ReverseTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
};

fn rebuildForwardWithoutRemovedDestinations(
    graph: *graph_core.GraphCore,
    node_index: u32,
    published_adj: types.NodeAdj,
    allocs: *mutation_common.PrePublishAllocations,
) !ForwardTombstoneCompaction {
    var result = try sortedRebuildForward(
        graph,
        published_adj.first_block_fwd,
        published_adj.block_count_fwd,
        published_adj.group_count_fwd,
        published_adj.first_group_fwd,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);

    try allocs.adoptBlocks(graph.allocator, .fwd, result.new_blocks.items);

    var staging_adj = published_adj;
    try buildAdjacencyFromBlocks(&staging_adj, graph, .fwd, result.new_blocks.items, allocs);
    updateRepairDebt(graph, &staging_adj, node_index, .fwd);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after, .removed_count = 0 };
}

pub fn countReverseSourceMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_index: u32,
) !usize {
    var matches: usize = 0;
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) matches += 1;
            }
        }
    } else {
        var group_idx = first_group;
        var rev_src_visited: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            if (group_idx >= graph.group_count) return error.CorruptGraph;
            if (rev_src_visited >= group_count or rev_src_visited >= graph.group_count) return error.CorruptGraph;
            rev_src_visited += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) matches += 1;
                }
            }
            group_idx = group.next;
        }
    }
    return matches;
}

pub fn prepareReverseWithoutSource(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_index: u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    const matches = try countReverseSourceMatches(graph, first_block, block_count, group_count, first_group, source_index);
    if (matches != 1) return error.CorruptGraph;
    return sortedRebuildReverse(graph, first_block, block_count, group_count, first_group, source_index, allocator);
}

fn rebuildReverseWithoutSource(
    graph: *graph_core.GraphCore,
    destination_index: u32,
    published_adj: types.NodeAdj,
    source_index: u32,
    allocs: *mutation_common.PrePublishAllocations,
) !ReverseTombstoneCompaction {
    var result = try prepareReverseWithoutSource(
        graph,
        published_adj.first_block_rev,
        published_adj.block_count_rev,
        published_adj.group_count_rev,
        published_adj.first_group_rev,
        source_index,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);

    try allocs.adoptBlocks(graph.allocator, .rev, result.new_blocks.items);

    var staging_adj = published_adj;
    try buildAdjacencyFromBlocks(&staging_adj, graph, .rev, result.new_blocks.items, allocs);
    updateRepairDebt(graph, &staging_adj, destination_index, .rev);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after };
}

const ReverseCleanupTarget = struct {
    node_buffer: *types.NodeBuffer,
    published_adj_before: types.NodeAdj,
    staging_adj_after: types.NodeAdj,
    new_degree_rev: u16,
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

    var allocs = mutation_common.PrePublishAllocations{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const source_adj_before = node_mut.publishedAdj();
    const source_result = try rebuildForwardWithoutRemovedDestinations(graph, node.index, source_adj_before, &allocs);

    for (tombstone_destinations.items, claimed_dest_nodes.items) |destination_index, destination_node| {
        const destination_adj_before = destination_node.publishedAdj();
        const reverse_result = try rebuildReverseWithoutSource(graph, destination_index, destination_adj_before, node.index, &allocs);
        try reverse_updates.append(graph.allocator, .{
            .node_buffer = destination_node,
            .published_adj_before = destination_adj_before,
            .staging_adj_after = reverse_result.staging_adj,
            .new_degree_rev = if (destination_adj_before.flags.removed) 0 else @as(u16, @intCast(@min(reverse_result.live_after, constants.DEGREE_OVERFLOW))),
        });
    }

    allocs.disarm();

    for (reverse_updates.items) |update| {
        update.node_buffer.degree_rev = update.new_degree_rev;
        publishBothAdj(update.node_buffer, update.staging_adj_after);
        try retireAdjacencySide(graph, update.published_adj_before, .rev);
    }

    node_mut.degree_fwd = if (source_result.live_after < constants.DEGREE_OVERFLOW) @intCast(source_result.live_after) else constants.DEGREE_OVERFLOW;
    publishBothAdj(node_mut, source_result.staging_adj);
    try retireAdjacencySide(graph, source_adj_before, .fwd);

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
        if (block_count == 0) return 0;
        // Single block with repair debt: tombstones (detected by
        // computeNeedsRepair) or grouped layout awaiting canonicalization
        // (group_count > 0 — not detected by computeNeedsRepair for
        // single blocks but the flag is already set).
        if (!computeNeedsRepair(graph, &node_adj, side) and group_count == 0) return 0;
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

    if (!computeNeedsRepair(graph, &staging_adj, side)) {
        updateRepairDebt(graph, &staging_adj, node.index, side);
        return 0;
    }

    var sorted = switch (side) {
        .fwd => try sortedRebuildForward(graph, first_block, block_count, group_count, first_group, graph.allocator),
        .rev => try sortedRebuildReverse(graph, first_block, block_count, group_count, first_group, null, graph.allocator),
    };
    defer sorted.new_blocks.deinit(graph.allocator);
    const live_total: usize = sorted.live_after;

    var allocs = mutation_common.PrePublishAllocations{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    try allocs.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    try buildAdjacencyFromBlocks(&staging_adj, graph, side, sorted.new_blocks.items, &allocs);

    updateRepairDebt(graph, &staging_adj, node.index, side);
    if (side == .fwd) {
        node_mut.degree_fwd = if (live_total < constants.DEGREE_OVERFLOW) @intCast(live_total) else constants.DEGREE_OVERFLOW;
    } else {
        node_mut.degree_rev = if (live_total < constants.DEGREE_OVERFLOW) @intCast(live_total) else constants.DEGREE_OVERFLOW;
    }
    allocs.disarm();
    publishBothAdj(node_mut, staging_adj);

    // Retire old blocks after publishing the replacement
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            try retireBlock(graph, @intCast(block_idx), side);
        }
    } else {
        var group_idx = first_group;
        var retire_visit: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            if (group_idx >= graph.group_count) return error.CorruptGraph;
            if (retire_visit >= group_count or retire_visit >= graph.group_count) return error.CorruptGraph;
            retire_visit += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                try retireBlock(graph, @intCast(block_idx), side);
            }
            const old_group = group_idx;
            group_idx = group.next;
            rcu.retireGroup(graph, old_group);
        }
    }
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
