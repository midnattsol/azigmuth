const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const shared = @import("edge/shared.zig");

pub fn rebuildAfterPreparedAppend(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !void {
    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, side_adj.block_count + 1);
    defer block_list.deinit(graph.allocator);
    try common.collectBlockList(
        graph,
        side_adj.*,
        prepared.old_block,
        prepared.new_block,
        if (prepared.old_block == null) prepared.new_block else null,
        &block_list,
    );
    try common.buildSideFromBlocks(side_adj, graph, block_list.items, scratch);
}

pub fn rebuildAfterSingleRemoval(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    old_block: u32,
    new_block: ?u32,
    scratch: *common.MutationScratch,
) !void {
    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    try common.collectBlockList(
        graph,
        published_side.*,
        old_block,
        new_block,
        null,
        &block_list,
    );
    try common.buildSideFromBlocks(staging_side, graph, block_list.items, scratch);
}
