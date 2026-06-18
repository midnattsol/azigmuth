const common = @import("common.zig");
const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_adjacency_buffers = @import("../../storage/node/adjacency_buffers.zig");

pub const DebugSegment = struct {
    segment: u32,
    start: u32,
    count: u32,
};

pub fn appendContiguousBlocks(
    blocks: *std.ArrayList(common.TraversedBlock),
    allocator: std.mem.Allocator,
    start: u32,
    count: u32,
) !void {
    for (start..start + count) |block_idx| {
        try blocks.append(allocator, .{ .block_idx = @intCast(block_idx) });
    }
}

pub fn spansOverlap(left_segment: DebugSegment, right_segment: DebugSegment) bool {
    const left_end = left_segment.start + left_segment.count;
    const right_end = right_segment.start + right_segment.count;
    return left_segment.start < right_end and right_segment.start < left_end;
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
    const side_view = common.sideAdjOf(adjacency, side);
    if (side_view.block_count == 0) return;
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_view)) return;

    if (common.segmentCount(adjacency, side) == 0) {
        try appendContiguousBlocks(blocks, allocator, common.firstBlock(adjacency, side), common.blockCount(adjacency, side));
        return;
    }

    var seen_spans: [64]DebugSegment = undefined;
    var seen_count: usize = 0;
    const expected_segments = common.segmentCount(adjacency, side);
    const first_segment_idx = common.firstSegment(adjacency, side);
    const end_segment = std.math.add(u32, first_segment_idx, expected_segments) catch {
        try violations.append(allocator, .{ .blocksegment_chain_cycle = .{ .node = node_id, .segment = first_segment_idx } });
        return;
    };
    if (end_segment > graph.loadSegmentCount()) {
        try violations.append(allocator, .{ .blocksegment_chain_cycle = .{ .node = node_id, .segment = first_segment_idx } });
        return;
    }

    for (first_segment_idx..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        const current_span = DebugSegment{ .segment = segment_idx, .start = segment.start, .count = segment.count };
        for (seen_spans[0..@min(seen_count, seen_spans.len)]) |seen| {
            if (spansOverlap(seen, current_span)) {
                try violations.append(allocator, .{ .blocksegment_overlap = .{ .node = node_id, .segment_a = seen.segment, .segment_b = segment_idx } });
            }
        }
        if (seen_count < seen_spans.len) seen_spans[seen_count] = current_span;
        seen_count += 1;

        for (segment.start..segment.start + segment.count) |block_idx_usize| {
            try blocks.append(allocator, .{ .block_idx = @intCast(block_idx_usize) });
        }
    }
}
