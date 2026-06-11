const std = @import("std");
const adjacency = @import("../adjacency/mod.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const rebuild_common = @import("edge/remove/rebuild/common.zig");

pub fn rebuildAfterSingleRemoval(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    old_block: u32,
    new_block: ?u32,
    comptime side: adjacency.AdjSide,
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
    // Bounded build: occupancy-floor or run-bound violations trigger the
    // synchronous dense repack instead of surfacing RepairRequired.
    staging_side.* = try rebuild_common.buildSideFromBlockListBounded(graph, scratch, &block_list, side);
}
