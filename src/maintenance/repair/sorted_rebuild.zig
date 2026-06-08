const std = @import("std");
const tombstones = @import("tombstones.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_adj = @import("../../adjacency/side_ops.zig");

const BlockIter = struct {
    block_idx: u32,
    live: u7,
    pos: u7,
    current_key: u32,
    current_id: u32 = 0,
};

const Scan = struct {
    live_after: usize = 0,
    block_count: usize = 0,
};

pub const SortedRebuildResult = struct {
    new_blocks: std.ArrayList(u32),
    live_after: usize,
};

fn blockIterLess(lhs: BlockIter, rhs: BlockIter) bool {
    if (lhs.current_key != rhs.current_key) return lhs.current_key < rhs.current_key;
    return lhs.current_id < rhs.current_id;
}

fn siftUp(heap: []BlockIter, start_idx: usize) void {
    var child_idx = start_idx;
    while (child_idx > 0) {
        const parent_idx = (child_idx - 1) / 2;
        if (!blockIterLess(heap[child_idx], heap[parent_idx])) break;
        std.mem.swap(BlockIter, &heap[parent_idx], &heap[child_idx]);
        child_idx = parent_idx;
    }
}

fn siftDown(heap: []BlockIter, start_idx: usize) void {
    var parent_idx = start_idx;
    while (true) {
        const left_idx = parent_idx * 2 + 1;
        if (left_idx >= heap.len) break;

        const right_idx = left_idx + 1;
        var min_idx = left_idx;
        if (right_idx < heap.len and blockIterLess(heap[right_idx], heap[left_idx])) {
            min_idx = right_idx;
        }
        if (!blockIterLess(heap[min_idx], heap[parent_idx])) break;

        std.mem.swap(BlockIter, &heap[parent_idx], &heap[min_idx]);
        parent_idx = min_idx;
    }
}

fn heapPush(heap: *std.ArrayList(BlockIter), item: BlockIter) void {
    heap.appendAssumeCapacity(item);
    siftUp(heap.items, heap.items.len - 1);
}

fn heapRemoveTop(heap: *std.ArrayList(BlockIter)) void {
    _ = heap.swapRemove(0);
    if (heap.items.len > 0) siftDown(heap.items, 0);
}

fn heapUpdateTop(heap: *std.ArrayList(BlockIter), item: BlockIter) void {
    heap.items[0] = item;
    siftDown(heap.items, 0);
}

fn keepSlot(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) bool {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    switch (side) {
        .fwd => return !tombstones.edgePointsToRemoved(graph, block, slot, .fwd),
        .rev => {
            if (skip_source) |source_idx| {
                if (block.sources[slot] == source_idx) return false;
            }
            return !tombstones.edgePointsToRemoved(graph, block, slot, .rev);
        },
    }
}

fn blockKey(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
) u32 {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    return switch (side) {
        .fwd => block.edges[slot].destination,
        .rev => block.sources[slot],
    };
}

fn blockId(graph: *const graph_core.GraphCore, block_idx: u32, slot: u7, comptime side: adjacency.AdjSide) u32 {
    if (side == .rev or !graph.multigraph_enabled) return 0;
    return page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).ids[slot];
}

fn scanBlock(
    graph: *const graph_core.GraphCore,
    scan: *Scan,
    block_idx: u32,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) !void {
    scan.block_count += 1;
    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    const live: u7 = @intCast(@popCount(block.mask));
    for (0..live) |slot_idx| {
        if (keepSlot(graph, block_idx, @intCast(slot_idx), side, skip_source)) {
            scan.live_after += 1;
        }
    }
}

fn firstPos(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    live: u7,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) ?u7 {
    var slot: u7 = 0;
    while (slot < live) : (slot += 1) {
        if (keepSlot(graph, block_idx, slot, side, skip_source)) return slot;
    }
    return null;
}

fn pushBlock(
    graph: *const graph_core.GraphCore,
    heap: *std.ArrayList(BlockIter),
    block_idx: u32,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    const live: u7 = @intCast(@popCount(block.mask));
    const pos = firstPos(graph, block_idx, live, side, skip_source) orelse return;

    heapPush(heap, .{
        .block_idx = block_idx,
        .live = live,
        .pos = pos,
        .current_key = blockKey(graph, block_idx, pos, side),
        .current_id = blockId(graph, block_idx, pos, side),
    });
}

fn writeItem(
    graph: *graph_core.GraphCore,
    out_block_idx: u32,
    out_slot: u7,
    iter: BlockIter,
    comptime side: adjacency.AdjSide,
) void {
    switch (side) {
        .fwd => {
            const src_block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .fwd);
            page_ops.edgeBlockAt(graph, out_block_idx, .fwd).edges[out_slot] = src_block.edges[iter.pos];
            if (graph.multigraph_enabled) {
                page_ops.edgeBlockFwdIdsAt(graph, out_block_idx).ids[out_slot] =
                    page_ops.edgeBlockFwdIdsAtConst(graph, iter.block_idx).ids[iter.pos];
            }
        },
        .rev => {
            const src_block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .rev);
            page_ops.edgeBlockAt(graph, out_block_idx, .rev).sources[out_slot] = src_block.sources[iter.pos];
        },
    }
}

fn advanceIter(
    graph: *const graph_core.GraphCore,
    iter: *BlockIter,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
) bool {
    var pos = iter.pos + 1;
    while (pos < iter.live) : (pos += 1) {
        if (!keepSlot(graph, iter.block_idx, pos, side, skip_source)) continue;
        iter.pos = pos;
        iter.current_key = blockKey(graph, iter.block_idx, pos, side);
        iter.current_id = blockId(graph, iter.block_idx, pos, side);
        return true;
    }
    return false;
}

fn sideAdj(
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
) types.SideAdj {
    return .{
        .first_block = first_block,
        .block_count = block_count,
        .group_count = group_count,
        .first_group = first_group,
    };
}

fn sortedRebuildSide(
    graph: *graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    var scan = Scan{};
    var scan_cursor = side_adj.BlockCursor.init(side_view);
    while (scan_cursor.next(graph)) |block_idx| {
        try scanBlock(graph, &scan, block_idx, side, skip_source);
    }

    if (scan.live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    const out_block_count = (scan.live_after + 63) / 64;
    var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_block_count);
    errdefer {
        for (new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, side);
        new_blocks.deinit(allocator);
    }

    var heap = try std.ArrayList(BlockIter).initCapacity(allocator, @max(1, scan.block_count));
    defer heap.deinit(allocator);

    var heap_cursor = side_adj.BlockCursor.init(side_view);
    while (heap_cursor.next(graph)) |block_idx| {
        try pushBlock(graph, &heap, block_idx, side, skip_source);
    }

    var out_block_idx: ?u32 = null;
    var out_slot: u7 = 0;

    while (heap.items.len > 0) {
        const current = heap.items[0];

        if (out_block_idx == null or out_slot == 64) {
            out_block_idx = try page_ops.allocBlock(graph, side);
            new_blocks.appendAssumeCapacity(out_block_idx.?);
            out_slot = 0;
        }

        writeItem(graph, out_block_idx.?, out_slot, current, side);
        out_slot += 1;
        if (out_slot == 64) {
            page_ops.edgeBlockAt(graph, out_block_idx.?, side).mask = constants.FULL_BLOCK_MASK;
        }

        var next = current;
        if (!advanceIter(graph, &next, side, skip_source)) {
            heapRemoveTop(&heap);
        } else {
            heapUpdateTop(&heap, next);
        }
    }

    if (out_block_idx) |block_idx| {
        page_ops.edgeBlockAt(graph, block_idx, side).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = scan.live_after };
}

pub fn sortedRebuildForward(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    return sortedRebuildSide(
        graph,
        sideAdj(first_block, block_count, group_count, first_group),
        .fwd,
        null,
        allocator,
    );
}

pub fn sortedRebuildReverse(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    skip_source: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    return sortedRebuildSide(
        graph,
        sideAdj(first_block, block_count, group_count, first_group),
        .rev,
        skip_source,
        allocator,
    );
}
