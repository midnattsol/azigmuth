const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency/mod.zig");
const node_adjacency_buffers = @import("../storage/node/adjacency_buffers.zig");

pub const LayoutShapeReport = struct {
    segmented_single_block: bool = false,
    chain_is_contiguous: bool = false,
    has_small_non_tail_segment: bool = false,
    has_underfull_non_tail_block: bool = false,
    segment_count_exceeded: bool = false,
    counted_segments: u16 = 0,
};

pub fn forEachSegmentInSide(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    if (side_view.segment_count == 0) return;
    try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);

    const end_segment = side_view.first_segment + side_view.segment_count;
    for (side_view.first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        const segment_offset: u16 = @intCast(segment_idx - side_view.first_segment);
        try callback(graph, ctx, segment_offset, segment.*, segment_offset + 1 == side_view.segment_count);
    }
}

pub fn analyzeSideLayout(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !LayoutShapeReport {
    var report = LayoutShapeReport{};

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_view)) {
        try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);
        report.chain_is_contiguous = true;
        return report;
    }

    if (side_view.block_count <= 1) {
        report.segmented_single_block = side_view.segment_count > 0;
        if (side_view.segment_count > 0) {
            try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);
            report.segment_count_exceeded = side_view.segment_count > constants.MAX_SEGMENTS_PER_NODE;
            report.counted_segments = side_view.segment_count;
            report.chain_is_contiguous = true;
        }
        return report;
    }

    if (side_view.segment_count == 0) {
        const end = side_view.first_block + side_view.block_count - 1;
        for (side_view.first_block..end) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            if (page_ops.blockAliveCount(graph, block_idx, side) < constants.MIN_OCCUPANCY) {
                report.has_underfull_non_tail_block = true;
                break;
            }
        }
        return report;
    }

    try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);
    report.chain_is_contiguous = true;
    report.segment_count_exceeded = side_view.segment_count > constants.MAX_SEGMENTS_PER_NODE;

    var visited: u16 = 0;
    var previous_segment_end: ?u32 = null;
    const end_segment = side_view.first_segment + side_view.segment_count;
    for (side_view.first_segment..end_segment) |segment_idx_usize| {
        visited += 1;
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        const is_last_segment = visited == side_view.segment_count;
        if (previous_segment_end) |expected_start| {
            if (segment.start != expected_start) report.chain_is_contiguous = false;
        }
        previous_segment_end = segment.start + segment.count;
        if (!is_last_segment and segment.count < 4) {
            report.has_small_non_tail_segment = true;
        }

        const end = if (is_last_segment) segment.start + segment.count - 1 else segment.start + segment.count;
        for (segment.start..end) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            if (page_ops.blockAliveCount(graph, block_idx, side) < constants.MIN_OCCUPANCY) {
                report.has_underfull_non_tail_block = true;
                break;
            }
        }
        if (report.has_underfull_non_tail_block and report.has_small_non_tail_segment and !report.chain_is_contiguous) {
            // Keep scanning only for counted_segments.
        }
    }
    report.counted_segments = visited;
    return report;
}
