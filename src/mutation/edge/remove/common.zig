const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const repair = @import("../../../maintenance/repair.zig");
const common = @import("../../common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const shared = @import("../shared.zig");
const node_adjacency_buffers = @import("../../../storage/node/adjacency_buffers.zig");

pub const DestinationMatchProbe = struct {
    found: ?common.AdjSlot = null,
    has_multiple: bool = false,
};

pub const RemoveState = struct {
    source_published_side: types.SideAdj,
    destination_published_side: types.SideAdj,
    old_source_segments: shared.OldSegmentSlots,
    old_destination_segments: shared.OldSegmentSlots,
};

pub const RemovalStaging = struct {
    source_staging: *types.SideAdj,
    destination_staging: *types.SideAdj,
};

pub const SingleRemovalPlans = remove_fast_path.SingleRemovalPlans;
pub const SingleRemovalBuilds = remove_finalize.SingleRemovalBuilds;
pub const RemovalPublishAdj = remove_finalize.RemovalPublishAdj;
pub const BulkRemovalResult = remove_finalize.BulkRemovalResult;

pub fn usesTinyPath(remove_state: *const RemoveState) bool {
    return node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&remove_state.source_published_side) or node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&remove_state.destination_published_side);
}

pub fn loadRemoveState(graph: *graph_core.GraphCore, endpoints: *const shared.EndpointState, source: types.NodeId, destination: types.NodeId) RemoveState {
    const source_published_side = node_access.publishedFwdFromState(graph, source, endpoints.source_state);
    const destination_published_side = node_access.publishedRevFromState(graph, destination, endpoints.destination_state);
    return .{
        .source_published_side = source_published_side,
        .destination_published_side = destination_published_side,
        .old_source_segments = shared.OldSegmentSlots.captureSide(&source_published_side),
        .old_destination_segments = shared.OldSegmentSlots.captureSide(&destination_published_side),
    };
}

pub fn prepareRemovalStaging(graph: *graph_core.GraphCore, endpoints: *const shared.EndpointState, source: types.NodeId, destination: types.NodeId) RemovalStaging {
    node_access.copyPublishedToStagingFwd(graph, source, endpoints.source_state);
    node_access.copyPublishedToStagingRev(graph, destination, endpoints.destination_state);
    return .{
        .source_staging = node_access.stagingFwd(graph, source, endpoints.source_state),
        .destination_staging = node_access.stagingRev(graph, destination, endpoints.destination_state),
    };
}

pub fn beginRemovalScratch() common.MutationScratch {
    return .{};
}

pub fn updateSingleRemovalDebt(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    staging: RemovalStaging,
    source: types.NodeId,
    destination: types.NodeId,
) RemovalPublishAdj {
    var source_publish_adj = common.nodeAdjForSide(staging.source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    var destination_publish_adj = common.nodeAdjForSide(staging.destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    return .{
        .source_publish_adj = source_publish_adj,
        .destination_publish_adj = destination_publish_adj,
    };
}
