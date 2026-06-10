const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const side_ops = @import("../../../adjacency/side_ops.zig");
const repair = @import("../../../maintenance/repair.zig");
const common = @import("../../common.zig");
const remove_common = @import("common.zig");
const remove_finalize = @import("finalize.zig");
const remove_rebuild = @import("rebuild.zig");
const shared = @import("../shared.zig");

pub fn probeForwardDestinationMatches(
    graph: *const graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    destination_idx: u32,
) !remove_common.DestinationMatchProbe {
    if (side_adj.block_count == 0) return .{};

    var result: remove_common.DestinationMatchProbe = .{};
    const Context = struct {
        destination_idx: u32,
        result: *remove_common.DestinationMatchProbe,
    };
    var context = Context{ .destination_idx = destination_idx, .result = &result };
    try side_ops.forEachForwardEntryInSide(graph, side_adj.*, &context, struct {
        fn callback(_: *const graph_core.GraphCore, inner_context: *Context, entry: side_ops.ForwardEntryView) !void {
            if (inner_context.result.has_multiple or entry.destination != inner_context.destination_idx) return;
            if (inner_context.result.found == null) {
                inner_context.result.found = .{ .block_idx = entry.block_idx, .slot = entry.slot };
            } else {
                inner_context.result.has_multiple = true;
            }
        }
    }.callback);

    return result;
}

fn rebuildBulkRemovalSides(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    staging: remove_common.RemovalStaging,
    source: types.NodeId,
    destination: types.NodeId,
    scratch: *common.MutationScratch,
) !remove_common.BulkRemovalResult {
    const forward_result = try remove_rebuild.rebuildForwardRemoveAll(graph, &remove_state.source_pub, destination.index, scratch);
    if (forward_result.removed <= 1) return error.CorruptGraph;

    staging.source_staging.* = forward_result.new_side;
    staging.destination_staging.* = try remove_rebuild.rebuildReverseRemoveCount(graph, &remove_state.destination_pub, source.index, forward_result.removed, scratch);

    var source_publish_adj = common.nodeAdjForSide(staging.source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    var destination_publish_adj = common.nodeAdjForSide(staging.destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    return .{
        .removed = forward_result.removed,
        .publish_adj = .{
            .source_publish_adj = source_publish_adj,
            .destination_publish_adj = destination_publish_adj,
        },
    };
}

pub fn removeBulkDestinationMatches(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
) !bool {
    const staging = remove_common.prepareRemovalStaging(graph, endpoints, source, destination);

    var scratch = remove_common.beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const result = try rebuildBulkRemovalSides(graph, endpoints, remove_state, staging, source, destination, &scratch);
    return remove_finalize.finalizeBulkRemoval(
        graph,
        &scratch,
        endpoints,
        remove_state.source_pub,
        remove_state.destination_pub,
        source,
        destination,
        result,
    );
}
