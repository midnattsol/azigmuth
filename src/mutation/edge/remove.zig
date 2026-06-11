const graph_core = @import("../../core/graph_core.zig");
const node_published_mod = @import("../../storage/node/published.zig");
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
            break :blk try removeSingleDispatch(graph, &endpoints, remove_state, source, destination, probe.found.?, null);
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
        break :blk try removeSingleDispatch(graph, &endpoints, remove_state, source, destination, forward_found, null);
    };
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}

/// Single-edge removal dispatch by side shape. Mixed tiny/block endpoints
/// take the mixed fast paths so a hub-with-tiny-leaves removal never pays an
/// O(side) rebuild of the hub's adjacency.
fn removeSingleDispatch(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: remove_common.RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    forward_found: common.AdjSlot,
    edge_id: ?u32,
) !bool {
    const source_tiny = node_published_mod.NodePublished.isTiny(&remove_state.source_pub);
    const destination_tiny = node_published_mod.NodePublished.isTiny(&remove_state.destination_pub);

    if (source_tiny and destination_tiny) {
        if (edge_id) |id| {
            return remove_tiny.removeByIdTinyCompatible(graph, endpoints, remove_state, source, destination, .{ .local = id }, forward_found);
        }
        return remove_tiny.removeSingleTinyCompatible(graph, endpoints, remove_state, source, destination, forward_found);
    }
    if (source_tiny) {
        return remove_tiny.removeSingleTinyForwardBlockReverse(graph, endpoints, remove_state, source, destination, edge_id);
    }
    if (destination_tiny) {
        return remove_tiny.removeSingleBlockForwardTinyReverse(graph, endpoints, remove_state, source, destination, forward_found);
    }
    return remove_single.removeSingleLocated(graph, endpoints, remove_state, source, destination, forward_found, true);
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

    const forward_found = common.findSlotInAdjById(
        graph,
        remove_state.source_pub.first_block,
        remove_state.source_pub.block_count,
        remove_state.source_pub.group_count,
        remove_state.source_pub.first_group,
        destination.index,
        edge_id.local,
    ) orelse return false;
    const removed = try removeSingleDispatch(graph, &endpoints, remove_state, source, destination, forward_found, edge_id.local);
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}
