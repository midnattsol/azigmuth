const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_published = @import("../../../storage/node/published.zig");
const types = @import("../../../core/types.zig");
const rcu = @import("../../../concurrency/rcu.zig");
const common = @import("../../common.zig");
const shared = @import("../shared.zig");

pub const RemovalBuild = struct {
    old_block: u32,
    new_block: u32,
    new_live: u7,
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
    if (endpoints.source_meta.degree_fwd == 0) return error.CorruptGraph;
    if (endpoints.destination_meta.degree_rev == 0) return error.CorruptGraph;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(endpoints.source_meta)) == @as(u64, @bitCast(endpoints.destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(endpoints.source_node_meta, endpoints.source_published, endpoints.source_node, endpoints.source_meta, merged_flags, -1, -1);
        return;
    }

    _ = common.publishStagedRev(endpoints.destination_node_meta, endpoints.destination_published, endpoints.destination_node, endpoints.destination_meta, destination_publish_adj.flags.needs_repair_rev, -1);
    _ = common.publishStagedFwd(endpoints.source_node_meta, endpoints.source_published, endpoints.source_node, endpoints.source_meta, source_publish_adj.flags.needs_repair_fwd, -1);
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
            endpoints.source_node_meta,
            endpoints.source_published,
            endpoints.source_node,
            endpoints.source_meta,
            merged_flags,
            -@as(i23, @intCast(removed)),
            -@as(i23, @intCast(removed)),
        );
        return;
    }

    _ = common.publishStagedRev(
        endpoints.destination_node_meta,
        endpoints.destination_published,
        endpoints.destination_node,
        endpoints.destination_meta,
        publish_adj.destination_publish_adj.flags.needs_repair_rev,
        -@as(i23, @intCast(removed)),
    );
    _ = common.publishStagedFwd(
        endpoints.source_node_meta,
        endpoints.source_published,
        endpoints.source_node,
        endpoints.source_meta,
        publish_adj.source_publish_adj.flags.needs_repair_fwd,
        -@as(i23, @intCast(removed)),
    );
}

fn retireRemoved(
    graph: *graph_core.GraphCore,
    source_old_groups: shared.OldGroupChain,
    destination_old_groups: shared.OldGroupChain,
    source_build: RemovalBuild,
    destination_build: RemovalBuild,
) !void {
    try rcu.retireBlockFwd(graph, source_build.old_block);
    try rcu.retireBlockRev(graph, destination_build.old_block);
    if (source_build.new_live == 0) try rcu.retireBlockFwd(graph, source_build.new_block);
    if (destination_build.new_live == 0) try rcu.retireBlockRev(graph, destination_build.new_block);
    source_old_groups.retire(graph);
    destination_old_groups.retire(graph);
}

/// Retires the storage superseded by a rebuilt removal: blocks marked during
/// the rebuild, the old grouped-run metadata, and old tiny slots. Unchanged
/// blocks are shared with the published rebuilt side and MUST stay live.
pub fn retireBulkRemovedSides(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    source_pub: types.SideAdj,
    destination_pub: types.SideAdj,
    old_source_groups: shared.OldGroupChain,
    old_destination_groups: shared.OldGroupChain,
) !void {
    try scratch.retireMarked(graph);

    if (node_published.NodePublished.isTiny(&source_pub)) {
        rcu.retireTinySlot(graph, source_pub.first_block, .fwd);
    } else {
        old_source_groups.retire(graph);
    }

    if (node_published.NodePublished.isTiny(&destination_pub)) {
        rcu.retireTinySlot(graph, destination_pub.first_block, .rev);
    } else {
        old_destination_groups.retire(graph);
    }
}

pub fn finalizeSingleRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    source_old_groups: shared.OldGroupChain,
    destination_old_groups: shared.OldGroupChain,
    source: types.NodeId,
    destination: types.NodeId,
    builds: SingleRemovalBuilds,
    publish_adj: RemovalPublishAdj,
) !bool {
    scratch.disarm();
    try publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try retireRemoved(graph, source_old_groups, destination_old_groups, builds.source_build, builds.destination_build);
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

pub fn finalizeBulkRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    source_pub: types.SideAdj,
    destination_pub: types.SideAdj,
    old_source_groups: shared.OldGroupChain,
    old_destination_groups: shared.OldGroupChain,
    source: types.NodeId,
    destination: types.NodeId,
    result: BulkRemovalResult,
) !bool {
    scratch.disarm();
    publishBulkRemoved(endpoints, source, destination, result.removed, result.publish_adj);
    try retireBulkRemovedSides(graph, scratch, source_pub, destination_pub, old_source_groups, old_destination_groups);
    _ = graph.edge_count.fetchSub(result.removed, .release);
    return true;
}
