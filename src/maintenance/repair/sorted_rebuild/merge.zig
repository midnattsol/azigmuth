const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const rebuild_emit = @import("emit.zig");
const rebuild_filter = @import("filter.zig");

pub const SortedRebuildResult = struct {
    new_blocks: std.ArrayList(u32),
    live_after: usize,
};

pub fn sortedRebuildSide(
    graph: *graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    const scan = try rebuild_filter.scanRebuildInput(graph, side_view, side, skip_source);

    if (scan.live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    var heap = try rebuild_filter.initHeap(graph, side_view, side, skip_source, allocator, scan.block_count);
    defer heap.deinit(allocator);
    const new_blocks = try rebuild_emit.emitMergedBlocks(graph, &heap, side, scan.live_after, allocator, skip_source);
    return .{ .new_blocks = new_blocks, .live_after = scan.live_after };
}
