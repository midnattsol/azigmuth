const std = @import("std");
const tombstones = @import("tombstones.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");

const BlockIter = struct {
    block_idx: u32,
    live: u7,
    pos: u7,
    current_key: u32,
    current_id: u32 = 0,
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

pub const SortedRebuildResult = struct {
    new_blocks: std.ArrayList(u32),
    live_after: usize,
};

pub fn sortedRebuildForward(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    var live_after: usize = 0;
    var max_iters: usize = 0;
    if (group_count > 0) {
        try adjacency.validateSideAdjLayout(graph, .{
            .first_block = first_block,
            .block_count = block_count,
            .group_count = group_count,
            .first_group = first_group,
        });
    }

    // Count live and determine how many iterators we need.
    if (group_count == 0) {
        max_iters = block_count;
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!tombstones.edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) live_after += 1;
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups: u16 = 0;
        while (visited_groups < group_count) : (visited_groups += 1) {
            const grp = page_ops.groupAtConst(graph, gidx);
            max_iters += grp.count;
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (!tombstones.edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) live_after += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    const out_blocks = (live_after + 63) / 64;
    var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_blocks);
    errdefer {
        for (new_blocks.items) |block| page_ops.freeBlock(graph, block, .fwd);
        new_blocks.deinit(allocator);
    }

    var iters = try std.ArrayList(BlockIter).initCapacity(allocator, @max(1, max_iters));
    defer iters.deinit(allocator);

    // Build iterator list
    if (group_count == 0) {
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
            const live: u7 = @intCast(@popCount(block.mask));
            var pos: u7 = 0;
            while (pos < live) : (pos += 1) {
                if (!tombstones.edgePointsToRemoved(graph, block, pos, .fwd)) break;
            }
            if (pos < live) {
                const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, @intCast(bi)) else null;
                heapPush(&iters, .{
                    .block_idx = @intCast(bi),
                    .live = live,
                    .pos = pos,
                    .current_key = block.edges[pos].destination,
                    .current_id = if (id_block) |fwd_ids| fwd_ids.ids[pos] else 0,
                });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups2: u16 = 0;
        while (visited_groups2 < group_count) : (visited_groups2 += 1) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
                const live: u7 = @intCast(@popCount(block.mask));
                var pos: u7 = 0;
                while (pos < live) : (pos += 1) {
                    if (!tombstones.edgePointsToRemoved(graph, block, pos, .fwd)) break;
                }
                if (pos < live) {
                    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, @intCast(bi)) else null;
                    heapPush(&iters, .{
                        .block_idx = @intCast(bi),
                        .live = live,
                        .pos = pos,
                        .current_key = block.edges[pos].destination,
                        .current_id = if (id_block) |fwd_ids| fwd_ids.ids[pos] else 0,
                    });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        const iter_ref = &iters.items[0];
        const block = page_ops.edgeBlockAtConst(graph, iter_ref.block_idx, .fwd);
        const edge = block.edges[iter_ref.pos];

        if (out_block == null or out_slot == 64) {
            out_block = try page_ops.allocBlock(graph, .fwd);
            new_blocks.appendAssumeCapacity(out_block.?);
            out_slot = 0;
        }

        const dst_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
        dst_block.edges[out_slot] = edge;
        if (graph.multigraph_enabled) {
            const src_id_block = page_ops.edgeBlockFwdIdsAtConst(graph, iter_ref.block_idx);
            page_ops.edgeBlockFwdIdsAt(graph, out_block.?, ).ids[out_slot] = src_id_block.ids[iter_ref.pos];
        }
        out_slot += 1;
        if (out_slot == 64) {
            const full_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
            full_block.mask = constants.FULL_BLOCK_MASK;
        }

        // Advance iterator, skip tombstones
        var next_iter = iter_ref.*;
        next_iter.pos += 1;
        while (next_iter.pos < next_iter.live) : (next_iter.pos += 1) {
            if (!tombstones.edgePointsToRemoved(graph, block, next_iter.pos, .fwd)) break;
        }
        if (next_iter.pos >= next_iter.live) {
            heapRemoveTop(&iters);
        } else {
            next_iter.current_key = block.edges[next_iter.pos].destination;
            if (graph.multigraph_enabled) {
                const src_id_block = page_ops.edgeBlockFwdIdsAtConst(graph, next_iter.block_idx);
                next_iter.current_id = src_id_block.ids[next_iter.pos];
            }
            heapUpdateTop(&iters, next_iter);
        }
    }

    if (out_block) |ob| {
        page_ops.edgeBlockAt(graph, ob, .fwd).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = live_after };
}

pub fn sortedRebuildReverse(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    skip_source_index: ?u32,
    allocator: std.mem.Allocator,
) !SortedRebuildResult {
    var live_after: usize = 0;
    var max_iters: usize = 0;
    if (group_count > 0) {
        try adjacency.validateSideAdjLayout(graph, .{
            .first_block = first_block,
            .block_count = block_count,
            .group_count = group_count,
            .first_group = first_group,
        });
    }

    if (group_count == 0) {
        max_iters = block_count;
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (skip_source_index != null and block.sources[slot] == skip_source_index.?) continue;
                if (tombstones.edgePointsToRemoved(graph, block, @intCast(slot), .rev)) continue;
                live_after += 1;
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups_rev1: u16 = 0;
        while (visited_groups_rev1 < group_count) : (visited_groups_rev1 += 1) {
            const grp = page_ops.groupAtConst(graph, gidx);
            max_iters += grp.count;
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (skip_source_index != null and block.sources[slot] == skip_source_index.?) continue;
                    if (tombstones.edgePointsToRemoved(graph, block, @intCast(slot), .rev)) continue;
                    live_after += 1;
                }
            }
            gidx = grp.next;
        }
    }

    if (live_after == 0) {
        return .{ .new_blocks = .empty, .live_after = 0 };
    }

    const out_blocks = (live_after + 63) / 64;
    var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_blocks);
    errdefer {
        for (new_blocks.items) |block| page_ops.freeBlock(graph, block, .rev);
        new_blocks.deinit(allocator);
    }

    var iters = try std.ArrayList(BlockIter).initCapacity(allocator, @max(1, max_iters));
    defer iters.deinit(allocator);

    if (group_count == 0) {
        for (first_block..first_block + block_count) |bi| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
            const live: u7 = @intCast(@popCount(block.mask));
            var pos: u7 = 0;
            while (pos < live) : (pos += 1) {
                if (skip_source_index != null and block.sources[pos] == skip_source_index.?) continue;
                if (tombstones.edgePointsToRemoved(graph, block, pos, .rev)) continue;
                break;
            }
            if (pos < live) {
                heapPush(&iters, .{
                    .block_idx = @intCast(bi),
                    .live = live,
                    .pos = pos,
                    .current_key = block.sources[pos],
                });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups_rev2: u16 = 0;
        while (visited_groups_rev2 < group_count) : (visited_groups_rev2 += 1) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .rev);
                const live: u7 = @intCast(@popCount(block.mask));
                var pos: u7 = 0;
                while (pos < live) : (pos += 1) {
                    if (skip_source_index != null and block.sources[pos] == skip_source_index.?) continue;
                    if (tombstones.edgePointsToRemoved(graph, block, pos, .rev)) continue;
                    break;
                }
                if (pos < live) {
                    heapPush(&iters, .{
                        .block_idx = @intCast(bi),
                        .live = live,
                        .pos = pos,
                        .current_key = block.sources[pos],
                    });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        const iter_ref = &iters.items[0];
        const block = page_ops.edgeBlockAtConst(graph, iter_ref.block_idx, .rev);
        const source_id = block.sources[iter_ref.pos];

        if (out_block == null or out_slot == 64) {
            out_block = try page_ops.allocBlock(graph, .rev);
            new_blocks.appendAssumeCapacity(out_block.?);
            out_slot = 0;
        }

        const dst_block = page_ops.edgeBlockAt(graph, out_block.?, .rev);
        dst_block.sources[out_slot] = source_id;
        out_slot += 1;
        if (out_slot == 64) {
            const full_block = page_ops.edgeBlockAt(graph, out_block.?, .rev);
            full_block.mask = constants.FULL_BLOCK_MASK;
        }

        var next_iter = iter_ref.*;
        next_iter.pos += 1;
        while (next_iter.pos < next_iter.live) : (next_iter.pos += 1) {
            if (skip_source_index != null and block.sources[next_iter.pos] == skip_source_index.?) continue;
            if (tombstones.edgePointsToRemoved(graph, block, next_iter.pos, .rev)) continue;
            break;
        }
        if (next_iter.pos >= next_iter.live) {
            heapRemoveTop(&iters);
        } else {
            next_iter.current_key = block.sources[next_iter.pos];
            heapUpdateTop(&iters, next_iter);
        }
    }

    if (out_block) |ob| {
        page_ops.edgeBlockAt(graph, ob, .rev).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = live_after };
}
