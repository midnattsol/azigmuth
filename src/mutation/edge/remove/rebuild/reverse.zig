const std = @import("std");
const constants = @import("../../../../core/constants.zig");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const node_published = @import("../../../../storage/node/published.zig");
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
    const live = @popCount(old_block.mask);
    if (live == 0) return remove_count;
    if (remove_count == 0) {
        // Published blocks are immutable under RCU: unchanged blocks are
        // shared between the old and the rebuilt side instead of cloned.
        try block_list.append(graph.allocator, block_idx);
        return 0;
    }

    var in_block: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_idx) in_block += 1;
    }
    if (in_block == 0) {
        try block_list.append(graph.allocator, block_idx);
        return remove_count;
    }

    const take = @min(in_block, remove_count);
    const new_live: u7 = @intCast(live - take);
    if (new_live == 0) {
        try scratch.markRetireBlock(graph.allocator, .rev, block_idx);
        return remove_count - take;
    }

    const new_block_idx = try scratch.allocBlock(graph, .rev);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .rev);
    var write: u7 = 0;
    var skipped: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_idx and skipped < take) {
            skipped += 1;
        } else {
            new_block.sources[write] = old_block.sources[slot];
            write += 1;
        }
    }
    new_block.mask = constants.denseMask(write);
    try block_list.append(graph.allocator, new_block_idx);
    try scratch.markRetireBlock(graph.allocator, .rev, block_idx);
    return remove_count - take;
}

fn collectReverseRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ReverseRemovalContext,
    block_idx: u32,
) !void {
    context.remaining = try appendReverseBlockRemovingSourceCount(@constCast(graph), context.scratch, context.block_list, block_idx, context.source_idx, context.remaining);
}

pub fn rebuildReverseRemoveCount(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    source_idx: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    if (node_published.NodePublished.isTiny(published_side)) return rebuild_tiny.rebuildTinyReverseRemoveCount(graph, published_side, source_idx, remove_count, scratch);

    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var context = ReverseRemovalContext{ .source_idx = source_idx, .remaining = remove_count, .scratch = scratch, .block_list = &block_list };
    try common.forEachBlockInSide(graph, published_side.*, .rev, &context, collectReverseRemovalBlock);
    if (context.remaining > 0) return error.CorruptGraph;
    return try rebuild_common.buildSideFromBlockList(graph, scratch, block_list.items);
}
