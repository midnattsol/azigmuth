const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_validity = @import("../../core/node_validity.zig");
pub fn sumBlockAlive(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) u64 {
    if (!common.blockExists(graph, block_idx, side)) return 0;
    return common.blockAlive(graph, block_idx, side);
}

pub fn sumContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    comptime side: common.Side,
) u64 {
    var total: u64 = 0;
    for (start..start + count) |block_idx| {
        total += sumBlockAlive(graph, @intCast(block_idx), side);
    }
    return total;
}

pub fn sumGroupedRuns(graph: *const graph_core.GraphCore, first_group: u32, group_count: u16, comptime side: common.Side) u64 {
    var total: u64 = 0;
    const end_group = std.math.add(u32, first_group, group_count) catch return total;
    if (end_group > graph.loadGroupCount()) return total;
    for (first_group..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        total += sumContiguousBlocks(graph, group.start, group.count, side);
    }

    return total;
}

pub fn sumAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) u64 {
    var total: u64 = 0;
    common.forEachNodeIdInAdj(graph, adjacency, side, &total, struct {
        fn callback(_: *const graph_core.GraphCore, inner_total: *u64, _: u32) !void {
            inner_total.* += 1;
        }
    }.callback) catch return total;
    return total;
}

pub fn countVisibleEntriesInBlock(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) u64 {
    const block = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd),
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev),
    };
    const alive = @min(common.blockAlive(graph, block_idx, side), constants.EDGES_PER_BLOCK);
    var total: u64 = 0;
    for (0..alive) |slot| {
        const candidate_idx = switch (side) {
            .fwd => block.destinations[slot],
            .rev => block.sources[slot],
        };
        if (node_validity.isNodeLiveIndex(graph, candidate_idx)) total += 1;
    }
    return total;
}

pub fn sumVisibleAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) u64 {
    if (adjacency.flags.removed) return 0;

    var total: u64 = 0;
    common.forEachNodeIdInAdj(graph, adjacency, side, &total, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_total: *u64, candidate_idx: u32) !void {
            if (node_validity.isNodeLiveIndex(inner_graph, candidate_idx)) inner_total.* += 1;
        }
    }.callback) catch return total;
    return total;
}
