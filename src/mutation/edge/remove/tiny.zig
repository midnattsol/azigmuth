const graph_core = @import("../../../core/graph_core.zig");
const node_published_mod = @import("../../../storage/node/published.zig");
const types = @import("../../../core/types.zig");
const common = @import("../../common.zig");
const remove_common = @import("common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const remove_rebuild = @import("rebuild.zig");
const remove_single = @import("single.zig");
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
    try remove_finalize.retireBulkRemovedSides(
        graph,
        scratch,
        remove_state.source_pub,
        remove_state.destination_pub,
        remove_state.old_source_groups,
        remove_state.old_destination_groups,
    );
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
    if (!node_published_mod.NodePublished.isTiny(&remove_state.source_pub) and forward_found == null) return error.CorruptGraph;

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
    _ = forward_found;

    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);
    const new_source = try remove_rebuild.rebuildForwardRemoveOneById(graph, &remove_state.source_pub, destination.index, edge_id.local, &scratch) orelse return false;
    return finalizeTinyCompatibleSingleRemoval(graph, endpoints, remove_state, source, destination, new_source, &scratch);
}

/// Hub→leaf fast path: the source forward side is block-sided but the
/// destination reverse side is tiny. The tiny-compatible path would rescan
/// and rebuild the WHOLE forward side (O(side), plus an O(E log E) repack
/// when non-tail blocks go underfull) for every removal; instead, remove the
/// located forward slot through the regular fast-path machinery (tail COW or
/// shared-block structural rebuild) and rebuild only the tiny reverse slot.
pub fn removeSingleBlockForwardTinyReverse(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    forward_found: common.AdjSlot,
) !bool {
    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const forward_plan = try remove_fast_path.planRemovalSide(graph, &remove_state.source_pub, forward_found, .fwd);
    const staging = remove_common.prepareRemovalStaging(graph, endpoints, source, destination);
    const source_build = try remove_fast_path.applyRemovalPlanSide(graph, staging.source_staging, &remove_state.source_pub, forward_plan, .fwd, &scratch, true);
    // Route the forward retirements through the bulk-style finalize.
    try scratch.markRetireBlock(graph.allocator, .fwd, source_build.old_block);
    if (source_build.new_alive_count == 0) try scratch.markRetireBlock(graph.allocator, .fwd, source_build.new_block);

    staging.destination_staging.* = try remove_rebuild.rebuildReverseRemoveCount(graph, &remove_state.destination_pub, source.index, 1, &scratch);

    const publish_adj = remove_common.updateSingleRemovalDebt(graph, endpoints, staging, source, destination);
    scratch.disarm();
    try remove_finalize.publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try remove_finalize.retireBulkRemovedSides(
        graph,
        &scratch,
        remove_state.source_pub,
        remove_state.destination_pub,
        remove_state.old_source_groups,
        remove_state.old_destination_groups,
    );
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

/// Leaf→hub fast path: tiny source forward side (cheap full rebuild, ≤ tiny
/// cap entries) + block-sided destination reverse handled through the located
/// fast-path machinery instead of a full reverse-side rebuild.
/// `edge_id` selects one identified parallel edge (multigraph byId removal);
/// null removes the single matching pair edge.
pub fn removeSingleTinyForwardBlockReverse(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    edge_id: ?u32,
) !bool {
    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const new_source = if (edge_id) |id| blk: {
        break :blk (try remove_rebuild.rebuildForwardRemoveOneById(graph, &remove_state.source_pub, destination.index, id, &scratch)) orelse return false;
    } else blk: {
        const forward_result = try remove_rebuild.rebuildForwardRemoveAll(graph, &remove_state.source_pub, destination.index, &scratch);
        if (forward_result.removed == 0) return false;
        if (forward_result.removed != 1) return error.CorruptGraph;
        break :blk forward_result.new_side;
    };

    const reverse_found = try remove_single.findReverseMatchForSingleRemoval(graph, &remove_state, source, endpoints.destination_published.publishedRevSortedFromMeta(endpoints.destination_meta));
    const reverse_plan = try remove_fast_path.planRemovalSide(graph, &remove_state.destination_pub, reverse_found, .rev);
    const staging = remove_common.prepareRemovalStaging(graph, endpoints, source, destination);
    staging.source_staging.* = new_source;
    const destination_build = try remove_fast_path.applyRemovalPlanSide(graph, staging.destination_staging, &remove_state.destination_pub, reverse_plan, .rev, &scratch, true);
    try scratch.markRetireBlock(graph.allocator, .rev, destination_build.old_block);
    if (destination_build.new_alive_count == 0) try scratch.markRetireBlock(graph.allocator, .rev, destination_build.new_block);

    const publish_adj = remove_common.updateSingleRemovalDebt(graph, endpoints, staging, source, destination);
    scratch.disarm();
    try remove_finalize.publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try remove_finalize.retireBulkRemovedSides(
        graph,
        &scratch,
        remove_state.source_pub,
        remove_state.destination_pub,
        remove_state.old_source_groups,
        remove_state.old_destination_groups,
    );
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}
