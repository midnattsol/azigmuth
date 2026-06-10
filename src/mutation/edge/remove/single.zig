const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const common = @import("../../common.zig");
const remove_common = @import("common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const shared = @import("../shared.zig");

fn findReverseMatchForSingleRemoval(
    graph: *graph_core.GraphCore,
    remove_state: *const remove_common.RemoveState,
    source: types.NodeId,
) !common.AdjSlot {
    if (node_published.NodePublished.isTiny(&remove_state.destination_pub)) {
        const slot = page_ops.tinyRevAtConst(graph, remove_state.destination_pub.first_block);
        const count = node_published.NodePublished.tinyCount(&remove_state.destination_pub);
        for (0..count) |entry_idx| {
            if (slot.sources[entry_idx] == source.index) {
                return .{ .block_idx = remove_state.destination_pub.first_block, .slot = @intCast(entry_idx) };
            }
        }
        return error.CorruptGraph;
    }

    return common.findSlotInAdj(
        graph,
        remove_state.destination_pub.first_block,
        remove_state.destination_pub.block_count,
        remove_state.destination_pub.group_count,
        remove_state.destination_pub.first_group,
        source.index,
        .rev,
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
    const reverse_found = try findReverseMatchForSingleRemoval(graph, &remove_state, source);
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
