const std = @import("std");
const constants = @import("../../../../core/constants.zig");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const node_published = @import("../../../../storage/node/published.zig");
const common = @import("../../../common.zig");
const rebuild_common = @import("common.zig");
const rebuild_tiny = @import("tiny.zig");

const ForwardRemovalContext = struct {
    destination_idx: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    removed: u32 = 0,
};

fn appendForwardBlockWithoutDestination(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
    destination_idx: u32,
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const old_ids = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx) else undefined;
    const live = @popCount(old_block.mask);
    if (live == 0) return 0;

    var removed: u32 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination == destination_idx) removed += 1;
    }
    if (removed == 0) {
        // Published blocks are immutable under RCU, so the rebuilt side may
        // reference unchanged blocks directly instead of cloning them.
        try block_list.append(graph.allocator, block_idx);
        return 0;
    }
    if (removed == live) {
        try scratch.markRetireBlock(graph.allocator, .fwd, block_idx);
        return removed;
    }

    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .fwd);
    const new_ids = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block_idx) else undefined;
    var write: u7 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination != destination_idx) {
            new_block.edges[write] = old_block.edges[slot];
            if (graph.multigraph_enabled) new_ids.ids[write] = old_ids.ids[slot];
            write += 1;
        }
    }
    new_block.mask = constants.denseMask(write);
    try block_list.append(graph.allocator, new_block_idx);
    try scratch.markRetireBlock(graph.allocator, .fwd, block_idx);
    return removed;
}

fn collectForwardRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ForwardRemovalContext,
    block_idx: u32,
) !void {
    context.removed += try appendForwardBlockWithoutDestination(@constCast(graph), context.scratch, context.block_list, block_idx, context.destination_idx);
}

fn appendSharedForwardBlock(
    graph: *graph_core.GraphCore,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
) !void {
    try block_list.append(graph.allocator, block_idx);
}

fn appendForwardBlockRemovingOneById(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
    destination_idx: u32,
    edge_id: u32,
) !bool {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const old_ids = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
    const live: u7 = @intCast(@popCount(old_block.mask));

    for (0..live) |slot| {
        if (old_block.edges[slot].destination != destination_idx or old_ids.ids[slot] != edge_id) continue;
        if (live == 1) {
            try scratch.markRetireBlock(graph.allocator, .fwd, block_idx);
            return true;
        }

        const new_block_idx = try scratch.allocBlock(graph, .fwd);
        const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .fwd);
        const new_ids = page_ops.edgeBlockFwdIdsAt(graph, new_block_idx);
        var write: u7 = 0;
        for (0..live) |copy_slot| {
            if (copy_slot == slot) continue;
            new_block.edges[write] = old_block.edges[copy_slot];
            new_ids.ids[write] = old_ids.ids[copy_slot];
            write += 1;
        }
        new_block.mask = constants.denseMask(write);
        try block_list.append(graph.allocator, new_block_idx);
        try scratch.markRetireBlock(graph.allocator, .fwd, block_idx);
        return true;
    }

    try appendSharedForwardBlock(graph, block_list, block_idx);
    return false;
}

pub fn rebuildForwardRemoveAll(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_idx: u32,
    scratch: *common.MutationScratch,
) !rebuild_common.ForwardRemovalResult {
    if (node_published.NodePublished.isTiny(published_side)) return rebuild_tiny.rebuildTinyForwardRemoveAll(graph, published_side, destination_idx, scratch);

    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var context = ForwardRemovalContext{ .destination_idx = destination_idx, .scratch = scratch, .block_list = &block_list };
    try common.forEachBlockInSide(graph, published_side.*, .fwd, &context, collectForwardRemovalBlock);
    return .{ .new_side = try rebuild_common.buildSideFromBlockList(graph, scratch, block_list.items), .removed = context.removed };
}

pub fn rebuildForwardRemoveOneById(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_idx: u32,
    edge_id: u32,
    scratch: *common.MutationScratch,
) !?types.SideAdj {
    if (node_published.NodePublished.isTiny(published_side)) return rebuild_tiny.rebuildTinyForwardRemoveOneById(graph, published_side, destination_idx, edge_id, scratch);

    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var removed_target_edge = false;
    const RemoveByIdContext = struct {
        destination_idx: u32,
        edge_id: u32,
        removed_target_edge: *bool,
        scratch: *common.MutationScratch,
        block_list: *std.ArrayList(u32),
    };
    var context = RemoveByIdContext{ .destination_idx = destination_idx, .edge_id = edge_id, .removed_target_edge = &removed_target_edge, .scratch = scratch, .block_list = &block_list };
    try common.forEachBlockInSide(graph, published_side.*, .fwd, &context, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, ctx: *RemoveByIdContext, block_idx: u32) !void {
            if (!ctx.removed_target_edge.*) {
                ctx.removed_target_edge.* = try appendForwardBlockRemovingOneById(@constCast(inner_graph), ctx.scratch, ctx.block_list, block_idx, ctx.destination_idx, ctx.edge_id);
                return;
            }
            try appendSharedForwardBlock(@constCast(inner_graph), ctx.block_list, block_idx);
        }
    }.callback);

    if (!removed_target_edge) return null;
    return try rebuild_common.buildSideFromBlockList(graph, scratch, block_list.items);
}
