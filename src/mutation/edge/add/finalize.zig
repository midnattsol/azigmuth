const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const repair = @import("../../../maintenance/repair.zig");
const common = @import("../../common.zig");
const shared = @import("../shared.zig");

pub const AddPublishAdj = struct {
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
};

pub fn updateAddedDebt(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    source_staging: types.SideAdj,
    destination_staging: types.SideAdj,
) AddPublishAdj {
    var source_publish_adj = common.nodeAdjForSide(source_staging, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    var destination_publish_adj = common.nodeAdjForSide(destination_staging, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    return .{
        .source_publish_adj = source_publish_adj,
        .destination_publish_adj = destination_publish_adj,
    };
}

pub fn finalizeAdded(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    publish_adj: AddPublishAdj,
    forward_prepared: shared.PreparedAppendBlock,
    forward_applied: shared.AppliedAppend,
    reverse_prepared: shared.PreparedAppendBlock,
    reverse_applied: shared.AppliedAppend,
    old_source_groups: shared.OldGroupChain,
    old_destination_groups: shared.OldGroupChain,
) !void {
    scratch.disarm();
    shared.publishAdded(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try shared.retireAdded(graph, forward_prepared, forward_applied, reverse_prepared, reverse_applied, old_source_groups, old_destination_groups);
    _ = graph.edge_count.fetchAdd(1, .release);
}
