const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_adjacency_buffers = @import("../../../storage/node/adjacency_buffers.zig");
const types = @import("../../../core/types.zig");
const rcu = @import("../../../concurrency/rcu.zig");
const common = @import("../../common.zig");
const shared = @import("../shared.zig");

pub const RemovalBuild = struct {
    old_block: u32,
    new_block: u32,
    new_alive_count: u7,
};

pub const SingleRemovalBuilds = struct {
    source_build: RemovalBuild,
    destination_build: RemovalBuild,
};

pub const RemovalPublishAdj = struct {
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
};

pub const BulkRemovalResult = struct {
    removed: u32,
    publish_adj: RemovalPublishAdj,
};

pub fn publishRemoved(
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
) !void {
    if (endpoints.source_state.degree_fwd == 0) return error.CorruptGraph;
    if (endpoints.destination_state.degree_rev == 0) return error.CorruptGraph;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(endpoints.source_state)) == @as(u64, @bitCast(endpoints.destination_state)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(endpoints.source_publication_cell, endpoints.source_buffers, endpoints.source_state, merged_flags, -1, -1, endpoints.source_buffers.publishedFwdSortedFromState(endpoints.source_state), endpoints.source_buffers.publishedRevSortedFromState(endpoints.source_state));
        return;
    }

    _ = common.publishStagedRev(endpoints.destination_publication_cell, endpoints.destination_buffers, endpoints.destination_state, destination_publish_adj.flags.needs_repair_rev, -1, endpoints.destination_buffers.publishedRevSortedFromState(endpoints.destination_state));
    _ = common.publishStagedFwd(endpoints.source_publication_cell, endpoints.source_buffers, endpoints.source_state, source_publish_adj.flags.needs_repair_fwd, -1, endpoints.source_buffers.publishedFwdSortedFromState(endpoints.source_state));
}

fn publishBulkRemoved(
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    removed: u32,
    publish_adj: RemovalPublishAdj,
) void {
    if (source.index == destination.index) {
        var merged_flags = publish_adj.source_publish_adj.flags;
        merged_flags.needs_repair_rev = publish_adj.destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = false;
        _ = common.publishBothDelta(
            endpoints.source_publication_cell,
            endpoints.source_buffers,
            endpoints.source_state,
            merged_flags,
            -@as(i23, @intCast(removed)),
            -@as(i23, @intCast(removed)),
            endpoints.source_buffers.publishedFwdSortedFromState(endpoints.source_state),
            endpoints.source_buffers.publishedRevSortedFromState(endpoints.source_state),
        );
        return;
    }

    _ = common.publishStagedRev(
        endpoints.destination_publication_cell,
        endpoints.destination_buffers,
        endpoints.destination_state,
        publish_adj.destination_publish_adj.flags.needs_repair_rev,
        -@as(i23, @intCast(removed)),
        endpoints.destination_buffers.publishedRevSortedFromState(endpoints.destination_state),
    );
    _ = common.publishStagedFwd(
        endpoints.source_publication_cell,
        endpoints.source_buffers,
        endpoints.source_state,
        publish_adj.source_publish_adj.flags.needs_repair_fwd,
        -@as(i23, @intCast(removed)),
        endpoints.source_buffers.publishedFwdSortedFromState(endpoints.source_state),
    );
}

fn retireRemoved(
    graph: *graph_core.GraphCore,
    source_old_segments: shared.OldSegmentSlots,
    destination_old_segments: shared.OldSegmentSlots,
    source_build: RemovalBuild,
    destination_build: RemovalBuild,
) !void {
    try rcu.retireBlockFwd(graph, source_build.old_block);
    try rcu.retireBlockRev(graph, destination_build.old_block);
    if (source_build.new_alive_count == 0) try rcu.retireBlockFwd(graph, source_build.new_block);
    if (destination_build.new_alive_count == 0) try rcu.retireBlockRev(graph, destination_build.new_block);
    source_old_segments.retire(graph);
    destination_old_segments.retire(graph);
}

/// Retires the storage superseded by a rebuilt removal: blocks marked during
/// the rebuild, the old edge-block segment metadata, and old tiny slots. Unchanged
/// blocks are shared with the published rebuilt side and MUST stay live.
pub fn retireBulkRemovedSides(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    source_published_side: types.SideAdj,
    destination_published_side: types.SideAdj,
    old_source_segments: shared.OldSegmentSlots,
    old_destination_segments: shared.OldSegmentSlots,
) !void {
    try scratch.retireMarked(graph);

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&source_published_side)) {
        rcu.retireTinySlot(graph, source_published_side.first_block, .fwd);
    } else {
        old_source_segments.retire(graph);
    }

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&destination_published_side)) {
        rcu.retireTinySlot(graph, destination_published_side.first_block, .rev);
    } else {
        old_destination_segments.retire(graph);
    }
}

pub fn finalizeSingleRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    source_old_segments: shared.OldSegmentSlots,
    destination_old_segments: shared.OldSegmentSlots,
    source: types.NodeId,
    destination: types.NodeId,
    builds: SingleRemovalBuilds,
    publish_adj: RemovalPublishAdj,
) !bool {
    scratch.disarm();
    try publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try retireRemoved(graph, source_old_segments, destination_old_segments, builds.source_build, builds.destination_build);
    // Single-removal scratch carries no superseded blocks, only the dropped
    // edge's property row (when edge_properties is enabled).
    try scratch.retireMarked(graph);
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

pub fn finalizeBulkRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    source_published_side: types.SideAdj,
    destination_published_side: types.SideAdj,
    old_source_segments: shared.OldSegmentSlots,
    old_destination_segments: shared.OldSegmentSlots,
    source: types.NodeId,
    destination: types.NodeId,
    result: BulkRemovalResult,
) !bool {
    scratch.disarm();
    publishBulkRemoved(endpoints, source, destination, result.removed, result.publish_adj);
    try retireBulkRemovedSides(graph, scratch, source_published_side, destination_published_side, old_source_segments, old_destination_segments);
    _ = graph.edge_count.fetchSub(result.removed, .release);
    return true;
}
