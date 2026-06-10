const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const sorted_rebuild = @import("sorted_rebuild.zig");

pub fn adoptSortedRebuildSide(
    graph: *graph_core.GraphCore,
    comptime side: adjacency.AdjSide,
    sorted: *const sorted_rebuild.SortedRebuildResult,
    scratch: *mutation_common.MutationScratch,
) !types.SideAdj {
    try scratch.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    var rebuilt_side: types.SideAdj = undefined;
    try side_ops.buildSideFromBlocks(&rebuilt_side, graph, sorted.new_blocks.items, scratch);
    return rebuilt_side;
}
