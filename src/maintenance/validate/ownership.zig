const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_adjacency_buffers = @import("../../storage/node/adjacency_buffers.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_validity = @import("../../core/node_validity.zig");

fn validateDebtQueue(queue: []const u32, node_count: u32) !void {
    for (queue) |node_idx| {
        if (node_idx >= node_count) return error.CorruptGraph;
    }
}

pub fn validateOwnedBlockFast(
    graph: *const graph_core.GraphCore,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    block_idx: u32,
    comptime side: common.Side,
) !void {
    if (!common.blockExists(graph, block_idx, side)) return error.CorruptGraph;
    if (!common.bitmapSet(owned_blocks, block_idx)) return error.CorruptGraph;
    if (common.bitmapIsSet(free_blocks, block_idx)) return error.CorruptGraph;
    if (common.bitmapIsSet(retired_blocks, block_idx)) return error.CorruptGraph;
}

pub fn validateAdjacencyOwnershipAndLayoutFast(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    owned_segments: []u64,
    free_segments: []const u64,
    retired_segments: []const u64,
    comptime side: common.Side,
) !void {
    const side_view = common.sideAdjOf(adjacency, side);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_view)) {
        try adjacency_mod.validateSideAdjLayoutForSide(graph, side_view, switch (side) {
            .fwd => .fwd,
            .rev => .rev,
        });
        return;
    }

    const count = common.blockCount(adjacency, side);
    const segments = common.segmentCount(adjacency, side);
    if (count == 0) {
        if (segments != 0) return error.CorruptGraph;
        return;
    }

    if (segments == 0) {
        for (common.firstBlock(adjacency, side)..common.firstBlock(adjacency, side) + count) |block_idx| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_idx), side);
        }
        return;
    }

    if (segments > constants.MAX_SEGMENTS_PER_NODE and !common.needsRepairFlag(adjacency, side)) {
        if (!adjacency.flags.removed) return error.CorruptGraph;
    }

    var visited_segments: u32 = 0;
    var counted_blocks: u32 = 0;
    const first_segment_idx = common.firstSegment(adjacency, side);
    const end_segment = std.math.add(u32, first_segment_idx, segments) catch return error.CorruptGraph;
    if (end_segment > graph.loadSegmentCount()) return error.CorruptGraph;

    for (first_segment_idx..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        visited_segments += 1;

        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (segment.count == 0) return error.CorruptGraph;

        if (!common.bitmapSet(owned_segments, segment_idx)) return error.CorruptGraph;
        if (common.bitmapIsSet(free_segments, segment_idx)) return error.CorruptGraph;
        if (common.bitmapIsSet(retired_segments, segment_idx)) return error.CorruptGraph;

        for (segment.start..segment.start + segment.count) |block_idx| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_idx), side);
        }
        counted_blocks += segment.count;
    }

    if (counted_blocks != count) return error.CorruptGraph;
}
pub fn validateRepairDebtFast(graph: *const graph_core.GraphCore, node_count: u32) !void {
    try validateDebtQueue(graph.repair_fwd.items, node_count);
    try validateDebtQueue(graph.repair_rev.items, node_count);
}
