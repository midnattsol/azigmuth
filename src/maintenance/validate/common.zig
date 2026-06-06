const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");

pub fn forwardHasTombstone(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj) bool {
    const block_count = adjacency.block_count_fwd;
    if (block_count == 0) return false;
    const first_block = adjacency.first_block_fwd;
    const group_count = adjacency.group_count_fwd;
    const first_group = adjacency.first_group_fwd;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const dst = block.edges[slot].destination;
                if (dst < graph.publishedNodeCount() and
                    node_validity.isNodeRemovedIndex(graph, dst)) return true;
            }
        }
        return false;
    }

    var group_idx = first_group;
    var visited: u32 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (visited >= graph.group_count or group_idx >= graph.group_count) break;
        visited += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const dst = block.edges[slot].destination;
                if (dst < graph.publishedNodeCount() and
                    node_validity.isNodeRemovedIndex(graph, dst)) return true;
            }
        }
        group_idx = group.next;
    }
    return false;
}

pub const Side = enum { fwd, rev };
pub const StackKindFast = enum { free, retired };

pub const MAX_TRACKED_BLOCKS: usize = constants.MAX_EDGE_BLOCK_PAGES * constants.EDGE_BLOCKS_PER_PAGE;
pub const TRACKED_BLOCK_BITMAP_WORDS: usize = (MAX_TRACKED_BLOCKS + 63) / 64;

pub const MAX_TRACKED_GROUPS: usize = constants.MAX_EDGE_GROUP_PAGES * constants.EDGE_GROUPS_PER_PAGE;
pub const TRACKED_GROUP_BITMAP_WORDS: usize = (MAX_TRACKED_GROUPS + 63) / 64;

pub const TraversedBlock = struct {
    block_index: u32,
};

pub fn bitmapSet(bitmap: []u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    const already = (bitmap[word_index] & mask) != 0;
    bitmap[word_index] |= mask;
    return !already;
}

pub fn bitmapIsSet(bitmap: []const u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    return (bitmap[word_index] & mask) != 0;
}

pub fn readerEnter(graph: *const graph_core.GraphCore) types.GraphError!rcu.ReaderToken {
    return try rcu.readerEnter(@constCast(graph));
}

pub fn readerExit(graph: *const graph_core.GraphCore, token: rcu.ReaderToken) void {
    rcu.readerExit(@constCast(graph), token);
}

pub fn blockCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.block_count_fwd,
        .rev => adjacency.block_count_rev,
    };
}

pub fn groupCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.group_count_fwd,
        .rev => adjacency.group_count_rev,
    };
}

pub fn firstBlock(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_block_fwd,
        .rev => adjacency.first_block_rev,
    };
}

pub fn firstGroup(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_group_fwd,
        .rev => adjacency.first_group_rev,
    };
}

pub fn allocatedBlockCount(graph: *const graph_core.GraphCore, comptime side: Side) u32 {
    return switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };
}

pub fn blockExists(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) bool {
    return block_index < allocatedBlockCount(graph, side);
}

pub fn blockMask(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) u64 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).mask,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).mask,
    };
}

pub fn blockKey(graph: *const graph_core.GraphCore, block_index: u32, slot: usize, comptime side: Side) u32 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).edges[slot].destination,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).sources[slot],
    };
}

pub fn needsRepairFlag(adjacency: types.NodeAdj, comptime side: Side) bool {
    return switch (side) {
        .fwd => adjacency.flags.needs_repair_fwd,
        .rev => adjacency.flags.needs_repair_rev,
    };
}
