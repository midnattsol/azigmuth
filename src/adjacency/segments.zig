const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("mod.zig");
const rcu = @import("../concurrency/rcu.zig");
const scratch_mod = @import("../mutation/scratch.zig");

pub const SegmentDesc = types.EdgeBlockSegment;

pub fn segmentCount(side_adj: types.SideAdj) u16 {
    if (side_adj.block_count == 0) return 0;
    return if (side_adj.segment_count == 0) 1 else side_adj.segment_count;
}

pub fn segmentAt(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, segment_offset: u16) ?SegmentDesc {
    if (side_adj.block_count == 0) return null;
    if (side_adj.segment_count == 0) {
        if (segment_offset != 0) return null;
        return .{ .start = side_adj.first_block, .count = side_adj.block_count };
    }
    if (segment_offset >= side_adj.segment_count) return null;
    const segment_idx = side_adj.first_segment + segment_offset;
    if (segment_idx >= graph.loadSegmentCount()) return null;
    const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
    return .{ .start = segment.start, .count = segment.count };
}

pub fn tailSegment(graph: *const graph_core.GraphCore, side_adj: types.SideAdj) ?SegmentDesc {
    const total_segments = segmentCount(side_adj);
    if (total_segments == 0) return null;
    return segmentAt(graph, side_adj, total_segments - 1);
}

pub fn cloneSegments(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    target_segment_count: u16,
    scratch: *scratch_mod.MutationScratch,
) !u32 {
    try adjacency.validateSideAdjLayout(graph, side_adj.*);
    std.debug.assert(side_adj.segment_count > 0);
    std.debug.assert(target_segment_count > 0);
    std.debug.assert(target_segment_count <= constants.MAX_SEGMENTS_PER_NODE);

    const first_segment_idx = try scratch.allocSegmentSlots(graph, target_segment_count);
    var segment_idx: u16 = 0;
    while (segment_idx < side_adj.segment_count and segment_idx < target_segment_count) : (segment_idx += 1) {
        page_ops.edgeBlockSegmentAt(graph, first_segment_idx + segment_idx).* = page_ops.edgeBlockSegmentAtConst(graph, side_adj.first_segment + segment_idx).*;
    }
    return first_segment_idx;
}

pub fn forEachSegment(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    const total_segments = segmentCount(side_adj);
    if (total_segments == 0) return;

    var segment_idx: u16 = 0;
    while (segment_idx < total_segments) : (segment_idx += 1) {
        const segment = segmentAt(graph, side_adj, segment_idx) orelse return error.CorruptGraph;
        try callback(graph, ctx, segment, segment_idx + 1 == total_segments);
    }
}

pub const BlockCursor = struct {
    side: types.SideAdj,
    current_block_idx: u32 = 0,
    blocks_remaining: u32 = 0,
    segment_idx: u32 = constants.END_OF_CHAIN,
    segments_remaining: u16 = 0,
    contiguous: bool = false,
    done: bool = true,

    pub fn init(side: types.SideAdj) BlockCursor {
        if (side.block_count == 0) {
            return .{ .side = side };
        }

        if (side.segment_count == 0) {
            return .{
                .side = side,
                .current_block_idx = side.first_block,
                .blocks_remaining = side.block_count,
                .segments_remaining = 1,
                .contiguous = true,
                .done = false,
            };
        }

        return .{
            .side = side,
            .segment_idx = side.first_segment,
            .segments_remaining = side.segment_count,
            .done = false,
        };
    }

    pub fn next(self: *BlockCursor, graph: *const graph_core.GraphCore) ?u32 {
        if (self.done) return null;

        while (self.blocks_remaining == 0) {
            if (self.contiguous or self.segments_remaining == 0) {
                self.done = true;
                return null;
            }
            if (self.segment_idx >= graph.loadSegmentCount()) {
                self.done = true;
                return null;
            }

            const segment = page_ops.edgeBlockSegmentAtConst(graph, self.segment_idx);
            self.current_block_idx = segment.start;
            self.blocks_remaining = segment.count;
            self.segment_idx += 1;
            self.segments_remaining -= 1;
        }

        const block_idx = self.current_block_idx;
        self.current_block_idx += 1;
        self.blocks_remaining -= 1;
        return block_idx;
    }
};

pub const SideBuilder = struct {
    segment_start_idx: u32 = 0,
    segment_block_count: u32 = 0,
    total_blocks: u32 = 0,
    first_block_set: bool = false,
    segments: [constants.MAX_SEGMENTS_PER_NODE]SegmentDesc = undefined,
    segment_count: u16 = 0,

    pub fn begin(side_adj: *types.SideAdj) SideBuilder {
        side_adj.first_block = 0;
        side_adj.block_count = 0;
        side_adj.segment_count = 0;
        side_adj.first_segment = 0;
        return .{};
    }

    pub fn appendBlock(
        self: *SideBuilder,
        side_adj: *types.SideAdj,
        graph: *graph_core.GraphCore,
        block_idx: u32,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        _ = graph;
        _ = scratch;
        if (self.segment_block_count > 0 and block_idx == self.segment_start_idx + self.segment_block_count) {
            self.segment_block_count += 1;
        } else {
            if (self.segment_block_count > 0) try self.flush(side_adj);
            self.segment_start_idx = block_idx;
            self.segment_block_count = 1;
        }
    }

    fn flush(self: *SideBuilder, side_adj: *types.SideAdj) !void {
        if (self.segment_block_count == 0) return;
        if (!self.first_block_set) {
            side_adj.first_block = self.segment_start_idx;
            side_adj.block_count = self.segment_block_count;
            self.first_block_set = true;
        } else if (self.segment_count == 0) {
            self.segments[0] = .{ .start = side_adj.first_block, .count = side_adj.block_count };
            self.segments[1] = .{ .start = self.segment_start_idx, .count = self.segment_block_count };
            self.segment_count = 2;
        } else {
            if (self.segment_count >= constants.MAX_SEGMENTS_PER_NODE) return error.RepairRequired;
            self.segments[self.segment_count] = .{ .start = self.segment_start_idx, .count = self.segment_block_count };
            self.segment_count += 1;
        }
        self.total_blocks += self.segment_block_count;
        self.segment_block_count = 0;
    }

    pub fn finish(
        self: *SideBuilder,
        side_adj: *types.SideAdj,
        graph: *graph_core.GraphCore,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        if (self.segment_block_count > 0) try self.flush(side_adj);
        side_adj.block_count = self.total_blocks;
        if (self.segment_count == 0) return;

        if (self.segment_count == 1) {
            side_adj.first_block = self.segments[0].start;
            side_adj.segment_count = 0;
            side_adj.first_segment = 0;
            return;
        }

        const first_segment_idx = try scratch.allocSegmentSlots(graph, self.segment_count);
        side_adj.first_segment = first_segment_idx;
        side_adj.segment_count = self.segment_count;
        var segment_idx: u16 = 0;
        while (segment_idx < self.segment_count) : (segment_idx += 1) {
            page_ops.edgeBlockSegmentAt(graph, first_segment_idx + segment_idx).* = .{
                .start = self.segments[segment_idx].start,
                .count = self.segments[segment_idx].count,
            };
        }
    }
};

pub fn collectBlockList(
    graph: *const graph_core.GraphCore,
    published_side_adj: types.SideAdj,
    old_block_idx: ?u32,
    new_block_idx: ?u32,
    append_block_idx: ?u32,
    out: *std.ArrayList(u32),
) !void {
    var cursor = BlockCursor.init(published_side_adj);
    while (cursor.next(graph)) |block_idx| {
        if (old_block_idx != null and block_idx == old_block_idx.?) {
            if (new_block_idx) |replacement_block_idx| try out.append(graph.allocator, replacement_block_idx);
        } else {
            try out.append(graph.allocator, block_idx);
        }
    }
    if (append_block_idx) |tail_block_idx| try out.append(graph.allocator, tail_block_idx);
}

pub fn buildSideFromBlocks(
    side_adj: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *scratch_mod.MutationScratch,
) !void {
    side_adj.first_block = 0;
    side_adj.block_count = 0;
    side_adj.segment_count = 0;
    side_adj.first_segment = 0;
    if (blocks.len == 0) return;

    var builder = SideBuilder.begin(side_adj);
    for (blocks) |block_idx| {
        try builder.appendBlock(side_adj, graph, block_idx, scratch);
    }
    try builder.finish(side_adj, graph, scratch);
}

pub fn retireSide(
    graph: *graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !void {
    if (side_adj.block_count == 0) return;

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        switch (side) {
            .fwd => try rcu.retireBlockFwd(graph, block_idx),
            .rev => try rcu.retireBlockRev(graph, block_idx),
        }
    }

    if (side_adj.segment_count == 0) return;
    rcu.retireSegmentSlots(graph, side_adj.first_segment, side_adj.segment_count);
}

pub fn retireSegment(
    graph: *graph_core.GraphCore,
    segment: SegmentDesc,
    comptime side: adjacency.AdjSide,
) !void {
    for (segment.start..segment.start + segment.count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        switch (side) {
            .fwd => try rcu.retireBlockFwd(graph, block_idx),
            .rev => try rcu.retireBlockRev(graph, block_idx),
        }
    }
}
