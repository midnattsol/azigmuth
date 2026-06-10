const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const common = @import("../../common.zig");
const remove_common = @import("common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const remove_rebuild = @import("rebuild.zig");
const shared = @import("../shared.zig");

fn finalizeTinyCompatibleSingleRemoval(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    new_source: types.SideAdj,
    scratch: *common.MutationScratch,
) !bool {
    const staging = remove_common.prepareRemovalStaging(graph, endpoints, source, destination);
    staging.source_staging.* = new_source;
    staging.destination_staging.* = try remove_rebuild.rebuildReverseRemoveCount(graph, &remove_state.destination_pub, source.index, 1, scratch);

    const publish_adj = remove_common.updateSingleRemovalDebt(graph, endpoints, staging, source, destination);

    scratch.disarm();
    try remove_finalize.publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try remove_finalize.retireBulkRemovedSides(graph, remove_state.source_pub, remove_state.destination_pub, endpoints);
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

pub fn removeSingleTinyCompatible(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    forward_found: ?common.AdjSlot,
) !bool {
    try remove_fast_path.ensureForwardFastPathAllowedIfBlock(graph, &remove_state.source_pub, forward_found);

    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const forward_result = try remove_rebuild.rebuildForwardRemoveAll(graph, &remove_state.source_pub, destination.index, &scratch);
    if (forward_result.removed == 0) return false;
    if (forward_result.removed != 1) return error.CorruptGraph;

    return finalizeTinyCompatibleSingleRemoval(graph, endpoints, remove_state, source, destination, forward_result.new_side, &scratch);
}

pub fn removeByIdTinyCompatible(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    edge_id: types.EdgeId,
    forward_found: ?common.AdjSlot,
) !bool {
    try remove_fast_path.ensureForwardFastPathAllowedIfBlock(graph, &remove_state.source_pub, forward_found);

    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);
    const new_source = try remove_rebuild.rebuildForwardRemoveOneById(graph, &remove_state.source_pub, destination.index, edge_id.local, &scratch) orelse return false;
    return finalizeTinyCompatibleSingleRemoval(graph, endpoints, remove_state, source, destination, new_source, &scratch);
}
