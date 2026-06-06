const common = @import("common.zig");
const stacks = @import("stacks.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
pub fn appendBlockShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    block_index: u32,
    comptime side: common.Side,
) !void {
    if (!common.blockExists(graph, block_index, side)) return;

    const mask = common.blockMask(graph, block_index, side);
    const live_count = @popCount(mask);
    const id_block = if (side == .fwd and graph.multigraph_enabled)
        page_ops.edgeBlockFwdIdsAtConst(graph, block_index)
    else
        null;

    if (mask != constants.denseMask(@intCast(live_count))) {
        try violations.append(allocator, .{ .mask_bit_out_of_range = .{ .node = node_id, .block = block_index } });
    }

    var prev_key: ?u32 = null;
    var prev_edge_id: u32 = 0;
    for (0..live_count) |slot| {
        const key = common.blockKey(graph, block_index, slot, side);
        if (key >= graph.publishedNodeCount()) {
            try violations.append(allocator, .{ .invalid_dst = .{ .node = node_id, .block = block_index, .slot = @intCast(slot), .dst = key } });
        }

        if (id_block) |fwd_ids| {
            const edge_id = fwd_ids.ids[slot];
            if (edge_id == 0) {
                try violations.append(allocator, .{ .invalid_edge_id = .{ .node = node_id, .block = block_index, .slot = @intCast(slot), .edge_id = edge_id } });
            }
            if (prev_key) |previous| {
                if (key < previous or (key == previous and edge_id <= prev_edge_id)) {
                    try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_index, .slot = @intCast(slot) } });
                }
            }
            prev_edge_id = edge_id;
        } else if (prev_key) |previous| {
            if (key < previous or (!graph.multigraph_enabled and key == previous)) {
                try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_index, .slot = @intCast(slot) } });
            }
        }

        prev_key = key;
    }
}

pub fn appendContiguousBlocks(
    blocks: *std.ArrayList(common.TraversedBlock),
    allocator: std.mem.Allocator,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_index| {
        try blocks.append(allocator, .{ .block_index = @intCast(block_index) });
    }
}

pub const DebugGroupSpan = struct {
    group: u32,
    start: u32,
    count: u16,
};

pub fn spansOverlap(a: DebugGroupSpan, b: DebugGroupSpan) bool {
    const a_end = a.start + a.count;
    const b_end = b.start + b.count;
    return a.start < b_end and b.start < a_end;
}

pub fn collectAdjacencyBlocks(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    blocks: *std.ArrayList(common.TraversedBlock),
    comptime side: common.Side,
) !void {
    if (common.blockCount(adjacency, side) == 0) return;

    if (common.groupCount(adjacency, side) == 0) {
        try appendContiguousBlocks(blocks, allocator, common.firstBlock(adjacency, side), common.blockCount(adjacency, side));
        return;
    }

    var seen_spans: [64]DebugGroupSpan = undefined;
    var seen_count: usize = 0;
    const expected_groups = common.groupCount(adjacency, side);
    var visited_groups: u32 = 0;
    var group_index = common.firstGroup(adjacency, side);

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        if (visited_groups >= graph.group_count or visited_groups > expected_groups) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        const current_span = DebugGroupSpan{ .group = group_index, .start = group.start, .count = group.count };
        const comparable_count = @min(seen_count, seen_spans.len);
        for (seen_spans[0..comparable_count]) |seen| {
            if (spansOverlap(seen, current_span)) {
                try violations.append(allocator, .{ .blockgroup_overlap = .{ .node = node_id, .group_a = seen.group, .group_b = group_index } });
            }
        }
        if (seen_count < seen_spans.len) seen_spans[seen_count] = current_span;
        seen_count += 1;

        for (group.start..group.start + group.count) |block_index_usize| {
            try blocks.append(allocator, .{ .block_index = @intCast(block_index_usize) });
        }

        group_index = group.next;
    }
}

pub fn buildFreeBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: common.Side,
) !std.DynamicBitSetUnmanaged {
    const limit = common.allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.blockStackHeadIndex(graph, .free, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

pub fn buildRetiredBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: common.Side,
) !std.DynamicBitSetUnmanaged {
    const limit = common.allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.blockStackHeadIndex(graph, .retired, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

pub fn buildFreeGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.groupStackHeadIndexFast(graph, .free);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.groupMetaNextFast(graph, current) catch break;
    }
    return set;
}

pub fn buildRetiredGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.groupStackHeadIndexFast(graph, .retired);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.groupMetaNextFast(graph, current) catch break;
    }
    return set;
}

pub fn markOwnedBlock(
    owned_blocks: *std.DynamicBitSetUnmanaged,
    block_index: u32,
) bool {
    const bit_index: usize = @intCast(block_index);
    if (owned_blocks.isSet(bit_index)) return false;
    owned_blocks.set(bit_index);
    return true;
}

pub fn appendOwnershipAndShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    owned_blocks: *std.DynamicBitSetUnmanaged,
    free_blocks: *const std.DynamicBitSetUnmanaged,
    retired_blocks: *const std.DynamicBitSetUnmanaged,
    node_id: u32,
    blocks: []const common.TraversedBlock,
    comptime side: common.Side,
) !void {
    const tail_block_index = if (blocks.len > 0) blocks[blocks.len - 1].block_index else constants.END_OF_CHAIN;

    for (blocks) |traversed_block| {
        const block_index = traversed_block.block_index;
        if (!common.blockExists(graph, block_index, side)) continue;

        if (!markOwnedBlock(owned_blocks, block_index)) {
            try violations.append(allocator, .{ .block_double_owned = .{ .block = block_index } });
        }

        const bit_index: usize = @intCast(block_index);
        if (bit_index < free_blocks.bit_length and free_blocks.isSet(bit_index)) {
            try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = block_index } });
        }

        if (bit_index < retired_blocks.bit_length and retired_blocks.isSet(bit_index)) {
            try violations.append(allocator, .{ .retired_block_reachable = .{ .block = block_index, .node = node_id } });
        }

        try appendBlockShapeViolations(graph, allocator, violations, node_id, block_index, side);

        const live_count = @popCount(common.blockMask(graph, block_index, side));
        const non_tail_underfull = blocks.len > 1 and block_index != tail_block_index and live_count < constants.MIN_OCCUPANCY;
        if (non_tail_underfull) {
            try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = block_index, .occupancy = @intCast(live_count) } });
        }
    }
}
