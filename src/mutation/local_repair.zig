const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency/mod.zig");
const page_ops = @import("../storage/page_ops.zig");
const common = @import("common.zig");
const shared = @import("edge/shared.zig");
const side_segments = @import("../adjacency/segments.zig");

pub fn ensureTailCowSegmentConstraint(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    _ = graph;
    _ = side_adj;
    _ = prepared;
}

pub fn copyBlock(graph: *graph_core.GraphCore, source_block_idx: u32, destination_block_idx: u32, comptime side: adjacency.AdjSide) void {
    switch (side) {
        .fwd => {
            page_ops.edgeBlockAt(graph, destination_block_idx, .fwd).* = page_ops.edgeBlockAtConst(graph, source_block_idx, .fwd).*;
            page_ops.setBlockAliveCount(graph, destination_block_idx, .fwd, page_ops.blockAliveCount(graph, source_block_idx, .fwd));
            if (graph.multigraph_enabled) {
                page_ops.edgeBlockFwdIdsAt(graph, destination_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, source_block_idx).*;
            }
            if (graph.edge_properties_enabled) {
                page_ops.edgeBlockFwdPropsAt(graph, destination_block_idx).* = page_ops.edgeBlockFwdPropsAtConst(graph, source_block_idx).*;
            }
        },
        .rev => {
            page_ops.edgeBlockAt(graph, destination_block_idx, .rev).* = page_ops.edgeBlockAtConst(graph, source_block_idx, .rev).*;
            page_ops.setBlockAliveCount(graph, destination_block_idx, .rev, page_ops.blockAliveCount(graph, source_block_idx, .rev));
        },
    }
}

fn replaceTailSuffixWithFreshSpan(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
    discarded_block_idx: u32,
    append_new_block: bool,
) !u32 {
    if (side_adj.segment_count == 0) return error.RepairRequired;
    if (side_adj.segment_count < 2) return error.RepairRequired;

    const suffix_segment_idx = side_adj.segment_count - 2;
    const prefix_segment_count = side_adj.segment_count - 1;
    const penultimate_segment = side_segments.segmentAt(graph, side_adj.*, suffix_segment_idx) orelse return error.CorruptGraph;
    const tail_segment = side_segments.segmentAt(graph, side_adj.*, suffix_segment_idx + 1) orelse return error.CorruptGraph;

    scratch.freeTrackedBlock(graph, side, discarded_block_idx);

    const new_segment_block_count: u32 = penultimate_segment.count + tail_segment.count + @as(u32, if (append_new_block) 1 else 0);
    const first_block_idx = try scratch.allocFreshBlockSpan(graph, side, new_segment_block_count);

    var block_offset: u32 = 0;
    while (block_offset < penultimate_segment.count) : (block_offset += 1) {
        copyBlock(graph, penultimate_segment.start + block_offset, first_block_idx + block_offset, side);
    }
    while (block_offset < penultimate_segment.count + tail_segment.count) : (block_offset += 1) {
        const tail_offset = block_offset - penultimate_segment.count;
        copyBlock(graph, tail_segment.start + tail_offset, first_block_idx + block_offset, side);
    }

    const cloned_first_segment = try side_segments.cloneSegments(graph, side_adj, prefix_segment_count, scratch);
    const cloned_tail_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + prefix_segment_count - 1);
    cloned_tail_segment.start = first_block_idx;
    cloned_tail_segment.count = new_segment_block_count;
    side_adj.first_segment = cloned_first_segment;
    side_adj.segment_count = prefix_segment_count;
    if (append_new_block) side_adj.block_count += 1;

    return first_block_idx + new_segment_block_count - 1;
}

pub fn appendPreparedBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !?shared.AppliedAppend {
    if (side_adj.segment_count == 0) {
        if (prepared.new_block == side_adj.first_block + side_adj.block_count) {
            side_adj.block_count += 1;
            return .{ .block_idx = prepared.new_block };
        }

        const first_segment_idx = try scratch.allocSegmentSlots(graph, 2);
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx).* = .{
            .start = side_adj.first_block,
            .count = side_adj.block_count,
        };
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx + 1).* = .{
            .start = prepared.new_block,
            .count = 1,
        };
        side_adj.first_segment = first_segment_idx;
        side_adj.segment_count = 2;
        side_adj.block_count += 1;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.block_count == 1) {
        const segment = page_ops.edgeBlockSegmentAtConst(graph, side_adj.first_segment);
        if (prepared.new_block == segment.start + 1) {
            side_adj.first_block = segment.start;
            side_adj.block_count = 2;
            side_adj.segment_count = 0;
            side_adj.first_segment = 0;
            return .{ .block_idx = prepared.new_block };
        }
    }

    const published_tail_segment = page_ops.edgeBlockSegmentAtConst(graph, side_adj.first_segment + side_adj.segment_count - 1);
    if (prepared.new_block == published_tail_segment.start + published_tail_segment.count) {
        const cloned_first_segment = try side_segments.cloneSegments(graph, side_adj, side_adj.segment_count, scratch);
        const last_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + side_adj.segment_count - 1);
        side_adj.first_segment = cloned_first_segment;
        last_segment.count += 1;
        side_adj.block_count += 1;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.segment_count >= constants.MAX_SEGMENTS_PER_NODE) {
        const total_segments = side_segments.segmentCount(side_adj.*);
        const penultimate_segment = side_segments.segmentAt(graph, side_adj.*, total_segments - 2) orelse return error.CorruptGraph;
        const compacted_tail_segment = side_segments.segmentAt(graph, side_adj.*, total_segments - 1) orelse return error.CorruptGraph;
        return .{
            .block_idx = try replaceTailSuffixWithFreshSpan(graph, side_adj, side, scratch, prepared.new_block, true),
            .retired_segments = .{ penultimate_segment, compacted_tail_segment },
            .retired_segment_count = 2,
        };
    }

    const cloned_first_segment = try side_segments.cloneSegments(graph, side_adj, side_adj.segment_count + 1, scratch);
    page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + side_adj.segment_count).* = .{
        .start = prepared.new_block,
        .count = 1,
    };
    side_adj.first_segment = cloned_first_segment;
    side_adj.segment_count += 1;
    side_adj.block_count += 1;
    return .{ .block_idx = prepared.new_block };
}

pub fn replaceTailBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !?shared.AppliedAppend {
    if (side_adj.segment_count == 0) {
        if (side_adj.block_count == 1) {
            side_adj.first_block = prepared.new_block;
            return .{ .block_idx = prepared.new_block };
        }

        const first_segment_idx = try scratch.allocSegmentSlots(graph, 2);
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx).* = .{
            .start = side_adj.first_block,
            .count = side_adj.block_count - 1,
        };
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx + 1).* = .{
            .start = prepared.new_block,
            .count = 1,
        };
        side_adj.first_segment = first_segment_idx;
        side_adj.segment_count = 2;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.block_count == 1) {
        side_adj.first_block = prepared.new_block;
        side_adj.segment_count = 0;
        side_adj.first_segment = 0;
        return .{ .block_idx = prepared.new_block };
    }

    const published_tail_segment = page_ops.edgeBlockSegmentAtConst(graph, side_adj.first_segment + side_adj.segment_count - 1);
    if (published_tail_segment.count == 1) {
        const cloned_first_segment = try side_segments.cloneSegments(graph, side_adj, side_adj.segment_count, scratch);
        const last_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + side_adj.segment_count - 1);
        side_adj.first_segment = cloned_first_segment;
        last_segment.start = prepared.new_block;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.segment_count >= constants.MAX_SEGMENTS_PER_NODE) {
        const total_segments = side_segments.segmentCount(side_adj.*);
        const penultimate_segment = side_segments.segmentAt(graph, side_adj.*, total_segments - 2) orelse return error.CorruptGraph;
        const compacted_tail_segment = side_segments.segmentAt(graph, side_adj.*, total_segments - 1) orelse return error.CorruptGraph;
        return .{
            .block_idx = try replaceTailSuffixWithFreshSpan(graph, side_adj, side, scratch, prepared.new_block, false),
            .retire_prepared_old_block = false,
            .retired_segments = .{ penultimate_segment, compacted_tail_segment },
            .retired_segment_count = 2,
        };
    }

    const cloned_first_segment = try side_segments.cloneSegments(graph, side_adj, side_adj.segment_count + 1, scratch);
    const cloned_tail_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + side_adj.segment_count - 1);
    page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + side_adj.segment_count).* = .{
        .start = prepared.new_block,
        .count = 1,
    };
    cloned_tail_segment.count -= 1;
    side_adj.first_segment = cloned_first_segment;
    side_adj.segment_count += 1;
    return .{ .block_idx = prepared.new_block };
}

pub fn removeTailBlock(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    new_block: u32,
    new_alive_count: u7,
    scratch: *common.MutationScratch,
) !bool {
    if (published_side.segment_count == 0) {
        if (new_alive_count == 0) {
            staging_side.block_count -= 1;
            return true;
        }

        const first_segment_idx = try scratch.allocSegmentSlots(graph, 2);
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx).* = .{
            .start = published_side.first_block,
            .count = published_side.block_count - 1,
        };
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx + 1).* = .{
            .start = new_block,
            .count = 1,
        };
        staging_side.first_segment = first_segment_idx;
        staging_side.segment_count = 2;
        return true;
    }

    const tail_segment = page_ops.edgeBlockSegmentAtConst(graph, published_side.first_segment + published_side.segment_count - 1);
    if (new_alive_count == 0) {
        if (tail_segment.count > 1) {
            if (published_side.segment_count == 1) {
                staging_side.first_block = tail_segment.start;
                staging_side.segment_count = 0;
                staging_side.first_segment = 0;
            } else {
                const cloned_first_segment = try side_segments.cloneSegments(graph, published_side, published_side.segment_count, scratch);
                const cloned_tail_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + published_side.segment_count - 1);
                cloned_tail_segment.count -= 1;
                staging_side.first_segment = cloned_first_segment;
            }
            staging_side.block_count -= 1;
            return true;
        }

        if (published_side.segment_count == 1) return false;

        if (published_side.segment_count == 2) {
            const remaining_segment = page_ops.edgeBlockSegmentAtConst(graph, published_side.first_segment);
            staging_side.first_block = remaining_segment.start;
            staging_side.segment_count = 0;
            staging_side.first_segment = 0;
            staging_side.block_count -= 1;
            return true;
        }

        const cloned_first_segment = try side_segments.cloneSegments(graph, published_side, published_side.segment_count - 1, scratch);
        staging_side.first_segment = cloned_first_segment;
        staging_side.segment_count -= 1;
        staging_side.block_count -= 1;
        return true;
    }

    if (tail_segment.count == 1) {
        const cloned_first_segment = try side_segments.cloneSegments(graph, published_side, published_side.segment_count, scratch);
        const cloned_tail_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + published_side.segment_count - 1);
        cloned_tail_segment.start = new_block;
        staging_side.first_segment = cloned_first_segment;
        return true;
    }

    if (published_side.segment_count >= constants.MAX_SEGMENTS_PER_NODE) return false;

    const cloned_first_segment = try side_segments.cloneSegments(graph, published_side, published_side.segment_count + 1, scratch);
    const cloned_tail_segment = page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + published_side.segment_count - 1);
    page_ops.edgeBlockSegmentAt(graph, cloned_first_segment + published_side.segment_count).* = .{
        .start = new_block,
        .count = 1,
    };
    cloned_tail_segment.count -= 1;
    staging_side.first_segment = cloned_first_segment;
    staging_side.segment_count += 1;
    return true;
}
