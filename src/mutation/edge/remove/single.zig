const adjacency = @import("../../../adjacency/mod.zig");
const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const common = @import("../../common.zig");
const remove_common = @import("common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const shared = @import("../shared.zig");

pub fn findReverseMatchForSingleRemoval(
    graph: *graph_core.GraphCore,
    remove_state: *const remove_common.RemoveState,
    source: types.NodeId,
    reverse_sorted: bool,
) !common.AdjSlot {
    if (node_published.NodePublished.isTiny(&remove_state.destination_pub)) {
        const slot = page_ops.tinyBlockAtConst(graph, remove_state.destination_pub.first_block, .rev);
        const count = node_published.NodePublished.tinyCount(&remove_state.destination_pub);
        for (0..count) |entry_idx| {
            if (slot.sources[entry_idx] == source.index) {
                return .{ .block_idx = remove_state.destination_pub.first_block, .slot = @intCast(entry_idx) };
            }
        }
        return error.CorruptGraph;
    }

    // Reverse entries are bare source ids, so any matching entry is
    // interchangeable. Prefer a match in the tail block: recently added
    // edges live there and the single-removal fast path requires tail
    // locality on multi-block sides.
    if (adjacency.tailBlockIndexSide(graph, &remove_state.destination_pub)) |tail_block_idx| {
        const tail_block = page_ops.edgeBlockAtConst(graph, tail_block_idx, .rev);
        const tail_live = page_ops.blockLiveCount(graph, tail_block_idx, .rev);
        if (adjacency.searchInBlock(types.EdgeBlockRev, tail_block, tail_live, source.index)) |slot| {
            return .{ .block_idx = tail_block_idx, .slot = slot };
        }
    }

    return common.findSlotInAdj(
        graph,
        remove_state.destination_pub.first_block,
        remove_state.destination_pub.block_count,
        remove_state.destination_pub.group_count,
        remove_state.destination_pub.first_group,
        source.index,
        .rev,
        reverse_sorted,
    ) orelse error.CorruptGraph;
}

pub fn removeSingleLocated(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    forward_found: common.AdjSlot,
    allow_structural_rebuild: bool,
) !bool {
    const reverse_found = try findReverseMatchForSingleRemoval(graph, &remove_state, source, endpoints.destination_published.publishedRevSortedFromMeta(endpoints.destination_meta));
    const plans = try remove_fast_path.planSingleRemoval(graph, &remove_state.source_pub, &remove_state.destination_pub, forward_found, reverse_found);
    try remove_fast_path.ensureSingleRemovalLocality(graph, &remove_state.source_pub, &remove_state.destination_pub, forward_found, reverse_found, allow_structural_rebuild);

    const staging = remove_common.prepareRemovalStaging(graph, endpoints, source, destination);

    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const builds: remove_common.SingleRemovalBuilds = .{
        .source_build = try remove_fast_path.applyRemovalPlanSide(graph, staging.source_staging, &remove_state.source_pub, plans.forward_plan, .fwd, &scratch, allow_structural_rebuild),
        .destination_build = try remove_fast_path.applyRemovalPlanSide(graph, staging.destination_staging, &remove_state.destination_pub, plans.reverse_plan, .rev, &scratch, allow_structural_rebuild),
    };
    const publish_adj = remove_common.updateSingleRemovalDebt(graph, endpoints, staging, source, destination);

    return remove_finalize.finalizeSingleRemoval(
        graph,
        &scratch,
        endpoints,
        remove_state.old_source_groups,
        remove_state.old_destination_groups,
        source,
        destination,
        builds,
        publish_adj,
    );
}
