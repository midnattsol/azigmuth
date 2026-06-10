const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const repair = @import("../../../maintenance/repair.zig");
const common = @import("../../common.zig");
const remove_fast_path = @import("fast_path.zig");
const remove_finalize = @import("finalize.zig");
const shared = @import("../shared.zig");
const node_published = @import("../../../storage/node/published.zig");

pub const DestinationMatchProbe = struct {
    found: ?common.AdjSlot = null,
    has_multiple: bool = false,
};

pub const RemoveState = struct {
    source_pub: types.SideAdj,
    destination_pub: types.SideAdj,
    old_source_groups: shared.OldGroupChain,
    old_destination_groups: shared.OldGroupChain,
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
    return node_published.NodePublished.isTiny(&remove_state.source_pub) or node_published.NodePublished.isTiny(&remove_state.destination_pub);
}

pub fn loadRemoveState(graph: *graph_core.GraphCore, endpoints: *const shared.EndpointState, source: types.NodeId, destination: types.NodeId) RemoveState {
    const source_pub = node_access.publishedFwdFromMeta(graph, source, endpoints.source_meta);
    const destination_pub = node_access.publishedRevFromMeta(graph, destination, endpoints.destination_meta);
    return .{
        .source_pub = source_pub,
        .destination_pub = destination_pub,
        .old_source_groups = shared.OldGroupChain.captureSide(&source_pub),
        .old_destination_groups = shared.OldGroupChain.captureSide(&destination_pub),
    };
}

pub fn prepareRemovalStaging(graph: *graph_core.GraphCore, endpoints: *const shared.EndpointState, source: types.NodeId, destination: types.NodeId) RemovalStaging {
    node_access.copyPublishedToStagingFwd(graph, source, endpoints.source_meta);
    node_access.copyPublishedToStagingRev(graph, destination, endpoints.destination_meta);
    return .{
        .source_staging = node_access.stagingFwd(graph, source, endpoints.source_meta),
        .destination_staging = node_access.stagingRev(graph, destination, endpoints.destination_meta),
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
