const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const mutation_common = @import("../../mutation/common.zig");
const rebuild_common = @import("../../mutation/edge/remove/rebuild/common.zig");
const sorted_rebuild = @import("sorted_rebuild.zig");

pub fn adoptSortedRebuildSide(
    graph: *graph_core.GraphCore,
    comptime side: adjacency.AdjSide,
    sorted: *sorted_rebuild.SortedRebuildResult,
    scratch: *mutation_common.MutationScratch,
) !types.SideAdj {
    try scratch.adoptBlocks(graph.allocator, side, sorted.new_blocks.items);

    // The per-block allocations may come from a scattered free stack; the
    // bounded build coalesces the cheapest adjacent runs so a repair rebuild
    // can never itself exceed the run bound (and never surfaces
    // RepairRequired back to the caller it is supposed to unblock).
    return rebuild_common.buildSideFromBlockListBounded(graph, scratch, &sorted.new_blocks, side);
}
