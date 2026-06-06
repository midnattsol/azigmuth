const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");
pub fn validateBlockDense(graph: *const graph_core.GraphCore, block_index: u32, comptime side: common.Side) !void {
    if (!common.blockExists(graph, block_index, side)) return error.CorruptGraph;

    const mask = common.blockMask(graph, block_index, side);
    const live_count = @popCount(mask);
    if (mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
}

pub fn validateDenseInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: common.Side,
) !void {
    for (start..start + count) |block_index| {
        try validateBlockDense(graph, @intCast(block_index), side);
    }
}

pub fn validateDenseInGroupChain(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    comptime side: common.Side,
) !void {
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups > graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        try validateDenseInContiguousBlocks(graph, group.start, group.count, side);
        group_index = group.next;
    }
}

pub fn validateDenseMasks(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !void {
    if (common.blockCount(adjacency, side) == 0) return;

    if (common.groupCount(adjacency, side) == 0) {
        return validateDenseInContiguousBlocks(graph, common.firstBlock(adjacency, side), common.blockCount(adjacency, side), side);
    }

    return validateDenseInGroupChain(graph, common.firstGroup(adjacency, side), side);
}

pub fn validateBlockShapeFast(graph: *const graph_core.GraphCore, block_index: u32, comptime side: common.Side) !u64 {
    if (!common.blockExists(graph, block_index, side)) return error.CorruptGraph;
    const node_count = graph.publishedNodeCount();

    if (side == .fwd) {
        const block = page_ops.edgeBlockAtConst(graph, block_index, .fwd);
        const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_index) else null;
        const live_count = @popCount(block.mask);
        if (block.mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
        var prev: u32 = 0;
        var prev_id: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.edges[slot].destination;
            if (key >= node_count) return error.CorruptGraph;
            if (graph.multigraph_enabled) {
                const edge_id = id_block.?.ids[slot];
                if (edge_id == 0) return error.CorruptGraph;
                if (slot > 0) {
                    if (key < prev) return error.CorruptGraph;
                    if (key == prev and edge_id <= prev_id) return error.CorruptGraph;
                }
                prev_id = edge_id;
            } else if (slot > 0 and key <= prev) {
                return error.CorruptGraph;
            }
            prev = key;
        }
        return live_count;
    } else {
        const block = page_ops.edgeBlockAtConst(graph, block_index, .rev);
        const live_count = @popCount(block.mask);
        if (block.mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
        var prev: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.sources[slot];
            if (key >= node_count) return error.CorruptGraph;
            if (slot > 0 and (key < prev or (!graph.multigraph_enabled and key == prev))) return error.CorruptGraph;
            prev = key;
        }
        return live_count;
    }
}

pub fn validateContiguousBlocksFast(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: common.Side,
) !u64 {
    var total: u64 = 0;
    for (start..start + count) |block_index| {
        total += try validateBlockShapeFast(graph, @intCast(block_index), side);
    }
    return total;
}

pub fn validateGroupChainFast(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    expected_group_count: u16,
    comptime side: common.Side,
) !u64 {
    var total: u64 = 0;
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        total += try validateContiguousBlocksFast(graph, group.start, group.count, side);
        group_index = group.next;
    }

    if (visited_groups != expected_group_count) return error.CorruptGraph;
    return total;
}

pub fn validateAdjacencyBlocksFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !u64 {
    if (common.blockCount(adjacency, side) == 0) return 0;

    if (common.groupCount(adjacency, side) == 0) {
        return validateContiguousBlocksFast(graph, common.firstBlock(adjacency, side), common.blockCount(adjacency, side), side);
    }

    return validateGroupChainFast(graph, common.firstGroup(adjacency, side), common.groupCount(adjacency, side), side);
}

pub fn validateOccupancyFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !void {
    const count = common.blockCount(adjacency, side);
    if (count <= 1) return;

    if (common.groupCount(adjacency, side) == 0) {
        const end = common.firstBlock(adjacency, side) + count - 1;
        for (common.firstBlock(adjacency, side)..end) |block_index| {
            if (@popCount(common.blockMask(graph, @intCast(block_index), side)) < constants.MIN_OCCUPANCY) return error.CorruptGraph;
        }
        return;
    }

    var group_index = common.firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        const is_last_group = group.next == constants.END_OF_CHAIN;
        const end = if (is_last_group) group.start + group.count - 1 else group.start + group.count;
        for (group.start..end) |block_index| {
            if (@popCount(common.blockMask(graph, @intCast(block_index), side)) < constants.MIN_OCCUPANCY) return error.CorruptGraph;
        }
        group_index = group.next;
    }
}
