const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
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

pub fn sumGroupedRuns(graph: *const graph_core.GraphCore, first_group: u32, group_count: u16, comptime side: common.Side) u64 {
    var total: u64 = 0;
    const end_group = std.math.add(u32, first_group, group_count) catch return total;
    if (end_group > graph.group_count) return total;
    for (first_group..end_group) |group_index_usize| {
        const group_index: u32 = @intCast(group_index_usize);
        const group = page_ops.groupAtConst(graph, group_index);
        total += sumContiguousBlocks(graph, group.start, group.count, side);
    }

    return total;
}

pub fn sumAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) u64 {
    var total: u64 = 0;
    common.forEachRunInAdj(graph, adjacency, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *u64,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            inner_total.* += sumContiguousBlocks(inner_graph, start, count, side);
        }
    }.callback) catch return total;
    return total;
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

    var total: u64 = 0;
    common.forEachRunInAdj(graph, adjacency, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *u64,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_index| {
                inner_total.* += countVisibleEntriesInBlock(inner_graph, @intCast(block_index), side);
            }
        }
    }.callback) catch return total;
    return total;
}
