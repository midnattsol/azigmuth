const std = @import("std");
const constants = @import("../../../../core/constants.zig");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const node_adjacency_buffers = @import("../../../../storage/node/adjacency_buffers.zig");
const common = @import("../../../common.zig");
const rebuild_common = @import("common.zig");
const rebuild_tiny = @import("tiny.zig");

const ReverseRemovalContext = struct {
    source_idx: u32,
    remaining: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
};

fn appendReverseBlockRemovingSourceCount(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
    source_idx: u32,
    remove_count: u32,
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const alive = page_ops.blockAliveCount(graph, block_idx, .rev);
    if (alive == 0) return remove_count;
    if (remove_count == 0) {
        // Published blocks are immutable under RCU: unchanged blocks are
        // shared between the old and the rebuilt side instead of cloned.
        try block_list.append(graph.allocator, block_idx);
        return 0;
    }

    var in_block: u32 = 0;
    for (0..alive) |slot| {
        if (old_block.sources[slot] == source_idx) in_block += 1;
    }
    if (in_block == 0) {
        try block_list.append(graph.allocator, block_idx);
        return remove_count;
    }

    const take = @min(in_block, remove_count);
    const new_alive_count: u7 = @intCast(alive - take);
    if (new_alive_count == 0) {
        try scratch.markRetireBlock(graph.allocator, .rev, block_idx);
        return remove_count - take;
    }

    const new_block_idx = try scratch.allocBlock(graph, .rev);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .rev);
    var write: u7 = 0;
    var skipped: u32 = 0;
    for (0..alive) |slot| {
        if (old_block.sources[slot] == source_idx and skipped < take) {
            skipped += 1;
        } else {
            new_block.sources[write] = old_block.sources[slot];
            write += 1;
        }
    }
    page_ops.setBlockAliveCount(graph, new_block_idx, .rev, @intCast(write));
    try block_list.append(graph.allocator, new_block_idx);
    try scratch.markRetireBlock(graph.allocator, .rev, block_idx);
    return remove_count - take;
}

fn collectReverseRemovalBlock(
    graph: *const graph_core.GraphCore,
    ctx: *ReverseRemovalContext,
    block_idx: u32,
) !void {
    ctx.remaining = try appendReverseBlockRemovingSourceCount(@constCast(graph), ctx.scratch, ctx.block_list, block_idx, ctx.source_idx, ctx.remaining);
}

pub fn rebuildReverseRemoveCount(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    source_idx: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(published_side)) return rebuild_tiny.rebuildTinyReverseRemoveCount(graph, published_side, source_idx, remove_count, scratch);

    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var ctx = ReverseRemovalContext{ .source_idx = source_idx, .remaining = remove_count, .scratch = scratch, .block_list = &block_list };
    try common.forEachBlockInSide(graph, published_side.*, .rev, &ctx, collectReverseRemovalBlock);
    if (ctx.remaining > 0) return error.CorruptGraph;
    return try rebuild_common.buildSideFromBlockListBounded(graph, scratch, &block_list, .rev);
}
