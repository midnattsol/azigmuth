const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const sorted_rebuild_merge = @import("sorted_rebuild/merge.zig");

pub const SortedRebuildResult = sorted_rebuild_merge.SortedRebuildResult;

fn sideAdj(
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
) types.SideAdj {
    return .{
        .first_block = first_block,
        .block_count = block_count,
        .segment_count = segment_count,
        .first_segment = first_segment,
    };
}

pub fn sortedRebuildForward(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    return sorted_rebuild_merge.sortedRebuildSide(
        graph,
        sideAdj(first_block, block_count, segment_count, first_segment),
        .fwd,
        null,
        allocator,
    );
}

pub fn sortedRebuildReverse(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    return sorted_rebuild_merge.sortedRebuildSide(
        graph,
        sideAdj(first_block, block_count, segment_count, first_segment),
        .rev,
        skip_source,
        allocator,
    );
}
