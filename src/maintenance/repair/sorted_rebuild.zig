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
};

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
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups >= group_count or visited_groups >= graph.group_count) return error.CorruptGraph;
            visited_groups += 1;
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
                try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups2: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups2 >= group_count or visited_groups2 >= graph.group_count) return error.CorruptGraph;
            visited_groups2 += 1;
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |bi| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(bi), .fwd);
                const live: u7 = @intCast(@popCount(block.mask));
                var pos: u7 = 0;
                while (pos < live) : (pos += 1) {
                    if (!tombstones.edgePointsToRemoved(graph, block, pos, .fwd)) break;
                }
                if (pos < live) {
                    try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        // Find iterator with minimum key
        var min_idx: usize = 0;
        var min_key: u32 = std.math.maxInt(u32);
        for (iters.items, 0..) |iter, idx| {
            const block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .fwd);
            const key = block.edges[iter.pos].destination;
            if (key < min_key) { min_key = key; min_idx = idx; }
        }

        const iter_ref = &iters.items[min_idx];
        const block = page_ops.edgeBlockAtConst(graph, iter_ref.block_idx, .fwd);
        const edge = block.edges[iter_ref.pos];

        if (out_block == null or out_slot == 64) {
            out_block = try page_ops.allocBlock(graph, .fwd);
            new_blocks.appendAssumeCapacity(out_block.?);
            out_slot = 0;
        }

        const dst_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
        dst_block.edges[out_slot] = edge;
        out_slot += 1;
        if (out_slot == 64) {
            const full_block = page_ops.edgeBlockAt(graph, out_block.?, .fwd);
            full_block.mask = constants.FULL_BLOCK_MASK;
        }

        // Advance iterator, skip tombstones
        iter_ref.pos += 1;
        while (iter_ref.pos < iter_ref.live) : (iter_ref.pos += 1) {
            if (!tombstones.edgePointsToRemoved(graph, block, iter_ref.pos, .fwd)) break;
        }
        if (iter_ref.pos >= iter_ref.live) {
            _ = iters.swapRemove(min_idx);
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
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups_rev1 >= group_count or visited_groups_rev1 >= graph.group_count) return error.CorruptGraph;
            visited_groups_rev1 += 1;
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
                try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
            }
        }
    } else {
        var gidx = first_group;
        var visited_groups_rev2: u16 = 0;
        while (gidx != constants.END_OF_CHAIN) {
            if (gidx >= graph.group_count) return error.CorruptGraph;
            if (visited_groups_rev2 >= group_count or visited_groups_rev2 >= graph.group_count) return error.CorruptGraph;
            visited_groups_rev2 += 1;
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
                    try iters.append(allocator,.{ .block_idx = @intCast(bi), .live = live, .pos = pos });
                }
            }
            gidx = grp.next;
        }
    }

    var out_block: ?u32 = null;
    var out_slot: u7 = 0;

    while (iters.items.len > 0) {
        var min_idx: usize = 0;
        var min_key: u32 = std.math.maxInt(u32);
        for (iters.items, 0..) |iter, idx| {
            const block = page_ops.edgeBlockAtConst(graph, iter.block_idx, .rev);
            const key = block.sources[iter.pos];
            if (key < min_key) { min_key = key; min_idx = idx; }
        }

        const iter_ref = &iters.items[min_idx];
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

        iter_ref.pos += 1;
        while (iter_ref.pos < iter_ref.live) : (iter_ref.pos += 1) {
            if (skip_source_index != null and block.sources[iter_ref.pos] == skip_source_index.?) continue;
            if (tombstones.edgePointsToRemoved(graph, block, iter_ref.pos, .rev)) continue;
            break;
        }
        if (iter_ref.pos >= iter_ref.live) {
            _ = iters.swapRemove(min_idx);
        }
    }

    if (out_block) |ob| {
        page_ops.edgeBlockAt(graph, ob, .rev).mask = constants.denseMask(out_slot);
    }

    return .{ .new_blocks = new_blocks, .live_after = live_after };
}

