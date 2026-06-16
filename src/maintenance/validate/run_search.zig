const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_published = @import("../../storage/node/published.zig");

const CountContext = struct {
    target: u32,
    total: u32 = 0,
};

const ContainsContext = struct {
    target: u32,
    found: bool = false,
};

pub fn forEachRunInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    comptime side: common.Side,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    const block_count = common.blockCount(adjacency, side);
    if (block_count == 0) return;

    const group_count = common.groupCount(adjacency, side);
    if (group_count == 0) {
        try callback(graph, ctx, common.firstBlock(adjacency, side), block_count);
        return;
    }

    const first_group_idx = common.firstGroup(adjacency, side);
    const end_group = std.math.add(u32, first_group_idx, group_count) catch return error.CorruptGraph;
    if (end_group > graph.loadGroupCount()) return error.CorruptGraph;
    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        try callback(graph, ctx, group.start, group.count);
    }
}

pub fn runContainsTarget(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    target: u32,
    comptime side: common.Side,
) bool {
    return switch (side) {
        .fwd => findSlotInRun(graph, start, count, target, types.EdgeBlockFwd, .fwd) != null,
        .rev => findSlotInRun(graph, start, count, target, types.EdgeBlockRev, .rev) != null,
    };
}

/// Searches a run of `count` blocks for `target`. Tries binary search on block
/// key ranges first, then falls back to a linear scan because blocks may not be
/// globally sorted by key.
pub fn findSlotInRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    target: u32,
    comptime BlockType: type,
    comptime side: common.Side,
) ?u7 {
    if (count == 0) return null;

    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block_idx = start + mid;
        const block = switch (side) {
            .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd),
            .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev),
        };
        const alive: u7 = @intCast(@min(switch (side) {
            .fwd => page_ops.blockAliveCount(graph, block_idx, .fwd),
            .rev => page_ops.blockAliveCount(graph, block_idx, .rev),
        }, constants.EDGES_PER_BLOCK));
        if (alive == 0) break;
        const first_key = switch (side) {
            .fwd => block.destinations[0],
            .rev => block.sources[0],
        };
        const last_key = switch (side) {
            .fwd => block.destinations[alive - 1],
            .rev => block.sources[alive - 1],
        };
        if (target < first_key) {
            high = mid;
        } else if (target > last_key) {
            low = mid + 1;
        } else {
            if (adjacency_mod.searchInBlock(BlockType, block, alive, target)) |slot| return slot;
            break;
        }
    }

    for (start..start + count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const block = switch (side) {
            .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd),
            .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev),
        };
        const alive: u7 = @intCast(@min(switch (side) {
            .fwd => page_ops.blockAliveCount(graph, block_idx, .fwd),
            .rev => page_ops.blockAliveCount(graph, block_idx, .rev),
        }, constants.EDGES_PER_BLOCK));
        if (adjacency_mod.searchInBlock(BlockType, block, alive, target)) |slot| return slot;
    }
    return null;
}

pub fn adjacencyContains(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    target: u32,
    comptime side: common.Side,
) bool {
    const side_view = common.sideAdjOf(adjacency, side);
    if (side_view.block_count == 0) return false;

    if (node_published.NodePublished.isTiny(&side_view)) {
        const count = node_published.NodePublished.tinyCount(&side_view);
        switch (side) {
            .fwd => {
                const slot = page_ops.tinyBlockAtConst(graph, side_view.first_block, .fwd);
                for (0..count) |entry_idx| {
                    if (slot.entries[entry_idx].destination == target) return true;
                }
            },
            .rev => {
                const slot = page_ops.tinyBlockAtConst(graph, side_view.first_block, .rev);
                for (0..count) |entry_idx| {
                    if (slot.sources[entry_idx] == target) return true;
                }
            },
        }
        return false;
    }

    // Binary range search per run (findSlotInRun keeps the conservative
    // linear fallback for non-monotonic runs) instead of a full linear scan
    // of the adjacency — pair-consistency validation is O(E) of these.
    var contains = ContainsContext{ .target = target };
    forEachRunInAdj(graph, adjacency, side, &contains, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_contains: *ContainsContext, start: u32, count: u32) !void {
            if (runContainsTarget(inner_graph, start, count, inner_contains.target, side)) {
                inner_contains.found = true;
                return error.FoundTarget;
            }
        }
    }.callback) catch |err| {
        if (err == error.FoundTarget) return true;
        return false;
    };
    return contains.found;
}

pub fn countTargetMatches(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    target: u32,
    comptime side: common.Side,
) u32 {
    var count = CountContext{ .target = target };
    common.forEachNodeIdInAdj(graph, adjacency, side, &count, struct {
        fn callback(_: *const graph_core.GraphCore, inner_count: *CountContext, candidate: u32) !void {
            if (candidate == inner_count.target) inner_count.total += 1;
        }
    }.callback) catch return count.total;
    return count.total;
}
