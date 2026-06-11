const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const side_ops = @import("../../../adjacency/side_ops.zig");
const rebuild_emit = @import("emit.zig");
const rebuild_filter = @import("filter.zig");

pub const SortedRebuildResult = struct {
    new_blocks: std.ArrayList(u32),
    live_after: usize,
    /// Property rows of dropped (tombstoned/skipped) forward entries; the
    /// caller retires them after publishing the rebuilt side. Always empty
    /// for reverse rebuilds or when edge_properties is disabled.
    dropped_prop_rows: std.ArrayList(u32) = .empty,
};

pub fn sortedRebuildSide(
    graph: *graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    const scan = try rebuild_filter.scanRebuildInput(graph, side_view, side, skip_source);

    var dropped_rows: std.ArrayList(u32) = .empty;
    errdefer dropped_rows.deinit(allocator);
    const collect_dropped = side == .fwd and graph.edge_properties_enabled;
    const dropped: ?rebuild_filter.DroppedRows = if (collect_dropped)
        .{ .list = &dropped_rows, .allocator = allocator }
    else
        null;

    if (scan.live_after == 0) {
        // Everything is dropped: collect every entry's row directly.
        if (dropped) |collector| {
            var cursor = side_ops.BlockCursor.init(side_view);
            while (cursor.next(graph)) |block_idx| {
                const live: u7 = @intCast(page_ops.blockLiveCount(graph, block_idx, side));
                for (0..live) |slot| try collector.record(graph, block_idx, @intCast(slot));
            }
        }
        return .{ .new_blocks = .empty, .live_after = 0, .dropped_prop_rows = dropped_rows };
    }

    var heap = try rebuild_filter.initHeap(graph, side_view, side, skip_source, allocator, scan.block_count, dropped);
    defer heap.deinit(allocator);
    const new_blocks = try rebuild_emit.emitMergedBlocks(graph, &heap, side, scan.live_after, allocator, skip_source, dropped);
    return .{ .new_blocks = new_blocks, .live_after = scan.live_after, .dropped_prop_rows = dropped_rows };
}
