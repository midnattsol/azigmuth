const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("../common.zig");
const remove_bulk = @import("remove/bulk.zig");
const remove_common = @import("remove/common.zig");
const remove_single = @import("remove/single.zig");
const remove_rebuild = @import("remove/rebuild.zig");
const remove_tiny = @import("remove/tiny.zig");
const shared = @import("shared.zig");

/// Removes one edge from `source` to `destination`.
/// Returns false when no matching edge exists.
pub fn removeEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId) !bool {
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const remove_state = remove_common.loadRemoveState(graph, &endpoints, source, destination);
    const removed = if (graph.multigraph_enabled) blk: {
        const probe = try remove_bulk.probeForwardDestinationMatches(graph, &remove_state.source_pub, destination.index);
        if (probe.found == null) break :blk false;
        if (!probe.has_multiple) {
            if (remove_common.usesTinyPath(&remove_state)) {
                break :blk try remove_tiny.removeSingleTinyCompatible(graph, &endpoints, remove_state, source, destination, probe.found.?);
            }
            break :blk try remove_single.removeSingleLocated(graph, &endpoints, remove_state, source, destination, probe.found.?, true);
        }
        break :blk try remove_bulk.removeBulkDestinationMatches(graph, &endpoints, remove_state, source, destination);
    } else blk: {
        const forward_found = common.findSlotInAdj(
            graph,
            remove_state.source_pub.first_block,
            remove_state.source_pub.block_count,
            remove_state.source_pub.group_count,
            remove_state.source_pub.first_group,
            destination.index,
            .fwd,
            endpoints.source_published.publishedFwdSortedFromMeta(endpoints.source_meta),
        ) orelse break :blk false;
        if (remove_common.usesTinyPath(&remove_state)) {
            break :blk try remove_tiny.removeSingleTinyCompatible(graph, &endpoints, remove_state, source, destination, forward_found);
        }
        break :blk try remove_single.removeSingleLocated(graph, &endpoints, remove_state, source, destination, forward_found, true);
    };
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}

/// Removes one multigraph edge identified by `(destination, edge_id)`.
/// Returns false when no matching edge exists.
pub fn removeEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, edge_id: types.EdgeId) !bool {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const remove_state = remove_common.loadRemoveState(graph, &endpoints, source, destination);

    if (remove_common.usesTinyPath(&remove_state)) {
        const forward_found = common.findSlotInAdjById(
            graph,
            remove_state.source_pub.first_block,
            remove_state.source_pub.block_count,
            remove_state.source_pub.group_count,
            remove_state.source_pub.first_group,
            destination.index,
            edge_id.local,
        );
        const removed_tiny = try remove_tiny.removeByIdTinyCompatible(graph, &endpoints, remove_state, source, destination, edge_id, forward_found);
        if (!removed_tiny) return false;
        rcu.bumpEpoch(graph);
        writer_guard.end();
        return true;
    }

    const forward_found = common.findSlotInAdjById(
        graph,
        remove_state.source_pub.first_block,
        remove_state.source_pub.block_count,
        remove_state.source_pub.group_count,
        remove_state.source_pub.first_group,
        destination.index,
        edge_id.local,
    ) orelse return false;
    const removed = try remove_single.removeSingleLocated(graph, &endpoints, remove_state, source, destination, forward_found, true);
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}
