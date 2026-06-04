const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");
pub fn sumBlockLive(graph: *const graph_core.GraphCore, block_index: u32, comptime side: common.Side) u64 {
    if (!common.blockExists(graph, block_index, side)) return 0;
    return @popCount(common.blockMask(graph, block_index, side));
}

pub fn sumContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: common.Side,
) u64 {
    var total: u64 = 0;
    for (start..start + count) |block_index| {
        total += sumBlockLive(graph, @intCast(block_index), side);
    }
    return total;
}

pub fn sumGroupChain(graph: *const graph_core.GraphCore, first_group: u32, comptime side: common.Side) u64 {
    var total: u64 = 0;
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return total;
        if (visited_groups > graph.group_count) return total;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        total += sumContiguousBlocks(graph, group.start, group.count, side);
        group_index = group.next;
    }

    return total;
}

pub fn sumAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) u64 {
    if (common.blockCount(adjacency, side) == 0) return 0;

    if (common.groupCount(adjacency, side) == 0) {
        return sumContiguousBlocks(graph, common.firstBlock(adjacency, side), common.blockCount(adjacency, side), side);
    }

    return sumGroupChain(graph, common.firstGroup(adjacency, side), side);
}

pub fn countVisibleEntriesInBlock(graph: *const graph_core.GraphCore, block_index: u32, comptime side: common.Side) u64 {
    const block = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd),
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev),
    };
    const live = @popCount(block.mask);
    var total: u64 = 0;
    for (0..live) |slot| {
        const candidate_index = switch (side) {
            .fwd => block.edges[slot].destination,
            .rev => block.sources[slot],
        };
        if (node_validity.isNodeLiveIndex(graph, candidate_index)) total += 1;
    }
    return total;
}

pub fn sumVisibleAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) u64 {
    if (adjacency.flags.removed) return 0;
    if (common.blockCount(adjacency, side) == 0) return 0;

    var total: u64 = 0;
    if (common.groupCount(adjacency, side) == 0) {
        const start = common.firstBlock(adjacency, side);
        for (start..start + common.blockCount(adjacency, side)) |block_index| {
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        return total;
    }

    var group_index = common.firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return total;
        if (visited_groups >= graph.group_count or visited_groups >= common.groupCount(adjacency, side)) return total;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        group_index = group.next;
    }
    return total;
}
