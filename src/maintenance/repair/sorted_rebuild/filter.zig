const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_validity = @import("../../../core/node_validity.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const side_ops = @import("../../../adjacency/side_ops.zig");
const rebuild_heap = @import("heap.zig");

pub const Scan = struct {
    alive_after: usize = 0,
    block_count: usize = 0,
};

/// Collector for property rows of slots the rebuild drops (forward side,
/// edge_properties mode). firstPos/advanceIter together visit every slot of
/// every block exactly once, so each dropped row is recorded exactly once.
pub const DroppedRows = struct {
    list: *std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn record(self: DroppedRows, graph: *const graph_core.GraphCore, block_idx: u32, slot: u7) !void {
        const row = side_ops.readForwardEntryAtSlot(graph, block_idx, slot).prop_row;
        if (row != 0) try self.list.append(self.allocator, row);
    }
};

fn keepSlot(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) bool {
    const node_id = side_ops.readNodeIdAtSlot(graph, block_idx, slot, side);
    switch (side) {
        .fwd => return node_id < graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(graph, node_id),
        .rev => {
            if (skip_source) |source_idx| {
                if (node_id == source_idx) return false;
            }
            return node_id < graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(graph, node_id);
        },
    }
}

fn blockKey(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
) u32 {
    return side_ops.readNodeIdAtSlot(graph, block_idx, slot, side);
}

fn blockId(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
) u32 {
    if (side == .rev or !graph.multigraph_enabled) return 0;
    return side_ops.readForwardEntryAtSlot(graph, block_idx, slot).edge_id;
}

fn scanBlock(
    graph: *const graph_core.GraphCore,
    scan: *Scan,
    block_idx: u32,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) !void {
    scan.block_count += 1;
    const alive: u7 = @intCast(page_ops.blockAliveCount(graph, block_idx, side));
    for (0..alive) |slot_idx| {
        if (keepSlot(graph, block_idx, @intCast(slot_idx), side, skip_source)) {
            scan.alive_after += 1;
        }
    }
}

fn firstPos(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    alive: u7,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    dropped: ?DroppedRows,
) !?u7 {
    var slot: u7 = 0;
    while (slot < alive) : (slot += 1) {
        if (keepSlot(graph, block_idx, slot, side, skip_source)) return slot;
        if (dropped) |collector| try collector.record(graph, block_idx, slot);
    }
    return null;
}

fn pushBlock(
    graph: *const graph_core.GraphCore,
    heap: *std.ArrayList(rebuild_heap.BlockIter),
    block_idx: u32,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    dropped: ?DroppedRows,
) !void {
    const alive: u7 = @intCast(page_ops.blockAliveCount(graph, block_idx, side));
    const pos = (try firstPos(graph, block_idx, alive, side, skip_source, dropped)) orelse return;

    rebuild_heap.heapPush(heap, .{
        .block_idx = block_idx,
        .alive = alive,
        .pos = pos,
        .current_key = blockKey(graph, block_idx, pos, side),
        .current_id = blockId(graph, block_idx, pos, side),
    });
}

pub fn advanceIter(
    graph: *const graph_core.GraphCore,
    iter: *rebuild_heap.BlockIter,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    dropped: ?DroppedRows,
) !bool {
    var pos = iter.pos + 1;
    while (pos < iter.alive) : (pos += 1) {
        if (!keepSlot(graph, iter.block_idx, pos, side, skip_source)) {
            if (dropped) |collector| try collector.record(graph, iter.block_idx, pos);
            continue;
        }
        iter.pos = pos;
        iter.current_key = blockKey(graph, iter.block_idx, pos, side);
        iter.current_id = blockId(graph, iter.block_idx, pos, side);
        return true;
    }
    return false;
}

pub fn scanRebuildInput(
    graph: *graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) !Scan {
    var scan = Scan{};
    var scan_cursor = side_ops.BlockCursor.init(side_view);
    while (scan_cursor.next(graph)) |block_idx| {
        try scanBlock(graph, &scan, block_idx, side, skip_source);
    }
    return scan;
}

pub fn initHeap(
    graph: *graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
    block_count: usize,
    dropped: ?DroppedRows,
) !std.ArrayList(rebuild_heap.BlockIter) {
    var heap = try std.ArrayList(rebuild_heap.BlockIter).initCapacity(allocator, @max(1, block_count));
    errdefer heap.deinit(allocator);

    var heap_cursor = side_ops.BlockCursor.init(side_view);
    while (heap_cursor.next(graph)) |block_idx| {
        try pushBlock(graph, &heap, block_idx, side, skip_source, dropped);
    }
    return heap;
}
