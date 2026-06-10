const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");

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
