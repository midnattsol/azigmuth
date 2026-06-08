const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_validity = @import("../../core/node_validity.zig");

fn validateDebtQueue(queue: []const u32, node_count: u32) !void {
    for (queue) |node_index| {
        if (node_index >= node_count) return error.CorruptGraph;
    }
}

pub fn validateOwnedBlockFast(
    graph: *const graph_core.GraphCore,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    block_index: u32,
    comptime side: common.Side,
) !void {
    if (!common.blockExists(graph, block_index, side)) return error.CorruptGraph;
    if (!common.bitmapSet(owned_blocks, block_index)) return error.CorruptGraph;
    if (common.bitmapIsSet(free_blocks, block_index)) return error.CorruptGraph;
    if (common.bitmapIsSet(retired_blocks, block_index)) return error.CorruptGraph;
}

pub fn validateAdjacencyOwnershipAndLayoutFast(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    owned_groups: []u64,
    free_groups: []const u64,
    retired_groups: []const u64,
    comptime side: common.Side,
) !void {
    const count = common.blockCount(adjacency, side);
    const groups = common.groupCount(adjacency, side);
    if (count == 0) {
        if (groups != 0) return error.CorruptGraph;
        return;
    }

    if (groups == 0) {
        for (common.firstBlock(adjacency, side)..common.firstBlock(adjacency, side) + count) |block_index| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_index), side);
        }
        return;
    }

    if (groups > constants.MAX_GROUPS_PER_NODE and !common.needsRepairFlag(adjacency, side)) {
        if (!adjacency.flags.removed) return error.CorruptGraph;
    }

    var visited_groups: u32 = 0;
    var counted_blocks: u16 = 0;
    const first_group_idx = common.firstGroup(adjacency, side);
    const end_group = std.math.add(u32, first_group_idx, groups) catch return error.CorruptGraph;
    if (end_group > graph.group_count) return error.CorruptGraph;

    for (first_group_idx..end_group) |group_index_usize| {
        const group_index: u32 = @intCast(group_index_usize);
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;

        if (!common.bitmapSet(owned_groups, group_index)) return error.CorruptGraph;
        if (common.bitmapIsSet(free_groups, group_index)) return error.CorruptGraph;
        if (common.bitmapIsSet(retired_groups, group_index)) return error.CorruptGraph;

        for (group.start..group.start + group.count) |block_index| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_index), side);
        }
        counted_blocks += group.count;
    }

    if (counted_blocks != count) return error.CorruptGraph;
}
pub fn validateRepairDebtFast(graph: *const graph_core.GraphCore, node_count: u32) !void {
    try validateDebtQueue(graph.repair_fwd.items, node_count);
    try validateDebtQueue(graph.repair_rev.items, node_count);
}
