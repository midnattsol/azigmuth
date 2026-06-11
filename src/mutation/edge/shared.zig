const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_meta_mod = @import("../../storage/node/meta.zig");
const node_published_mod = @import("../../storage/node/published.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const side_runs = @import("../../adjacency/runs.zig");
const common = @import("../common.zig");
const node_validity = @import("../../core/node_validity.zig");

pub const PreparedAppendBlock = struct {
    old_block: ?u32 = null,
    new_block: u32,
    tail_index: ?u32 = null,
};

pub const AppliedAppend = struct {
    block_idx: u32,
    retire_prepared_old_block: bool = true,
    retired_runs: [2]side_runs.RunDesc = undefined,
    retired_run_count: u2 = 0,
};

pub const OldGroupChain = struct {
    first_group: ?u32 = null,
    group_count: u16 = 0,

    /// Captures the current grouped run metadata so it can be retired after publish.
    pub fn captureSide(side_adj: *const types.SideAdj) OldGroupChain {
        return .{
            .first_group = if (side_adj.group_count > 0) side_adj.first_group else null,
            .group_count = side_adj.group_count,
        };
    }

    /// Retires the previously captured grouped run metadata, if any.
    pub fn retire(self: OldGroupChain, graph: *graph_core.GraphCore) void {
        if (self.first_group) |first_group| {
            common.retireGroupChain(graph, first_group, self.group_count);
        }
    }
};

pub const EndpointState = struct {
    source_node_meta: *node_meta_mod.NodeMeta,
    destination_node_meta: *node_meta_mod.NodeMeta,
    source_published: *node_published_mod.NodePublished,
    destination_published: *node_published_mod.NodePublished,
    claims: common.ClaimedAdjacencies,
    source_meta: types.PublishedMeta,
    destination_meta: types.PublishedMeta,
    source_flags: types.NodeFlags,
    destination_flags: types.NodeFlags,
};

/// Claims both endpoint adjacencies for an edge mutation and snapshots their meta.
/// Fails with error.InvalidNode when either endpoint is absent or already removed.
pub fn claimEndpoints(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
) !EndpointState {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) {
        return error.InvalidNode;
    }

    const source_node_meta = page_ops.nodeMetaAt(graph, source);
    const destination_node_meta = page_ops.nodeMetaAt(graph, destination);
    // addNode guarantees published pages for every published node.
    const source_published = page_ops.nodePublishedAt(graph, source);
    const destination_published = if (source.index == destination.index) source_published else page_ops.nodePublishedAt(graph, destination);
    var claims = try common.tryClaimAdjacencies(graph, source.index, destination.index);
    errdefer claims.release();

    const source_meta = node_access.loadPublishedMetaAtConst(graph, source);
    const destination_meta = node_access.loadPublishedMetaAtConst(graph, destination);
    if (source_meta.removed or destination_meta.removed) return error.InvalidNode;

    return .{
        .source_node_meta = source_node_meta,
        .source_published = source_published,
        .destination_node_meta = destination_node_meta,
        .destination_published = destination_published,
        .claims = claims,
        .source_meta = source_meta,
        .destination_meta = destination_meta,
        .source_flags = source_meta.flags(),
        .destination_flags = destination_meta.flags(),
    };
}

/// Publishes staging data for a newly added edge on both endpoints.
/// `fwd_sorted` / `rev_sorted` describe whether the NEW side layouts remain
/// globally sorted (see addEdgeImpl's appendKeepsGloballySorted).
pub fn publishAdded(
    endpoints: *const EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
    fwd_sorted: bool,
    rev_sorted: bool,
) void {
    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(endpoints.source_meta)) == @as(u64, @bitCast(endpoints.destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(endpoints.source_node_meta, endpoints.source_published, endpoints.source_meta, merged_flags, 1, 1, fwd_sorted, rev_sorted);
        return;
    }

    _ = common.publishStagedRev(endpoints.destination_node_meta, endpoints.destination_published, endpoints.destination_meta, destination_publish_adj.flags.needs_repair_rev, 1, rev_sorted);
    _ = common.publishStagedFwd(endpoints.source_node_meta, endpoints.source_published, endpoints.source_meta, source_publish_adj.flags.needs_repair_fwd, 1, fwd_sorted);
}

/// Retires superseded blocks, runs, and group chains after addEdge publication.
pub fn retireAdded(
    graph: *graph_core.GraphCore,
    forward_prepared: PreparedAppendBlock,
    forward_applied: AppliedAppend,
    reverse_prepared: PreparedAppendBlock,
    reverse_applied: AppliedAppend,
    old_source_groups: OldGroupChain,
    old_destination_groups: OldGroupChain,
) !void {
    if (forward_applied.retire_prepared_old_block) {
        if (forward_prepared.old_block) |old_block| try rcu.retireBlockFwd(graph, old_block);
    }
    if (reverse_applied.retire_prepared_old_block) {
        if (reverse_prepared.old_block) |old_block| try rcu.retireBlockRev(graph, old_block);
    }

    var run_idx: u2 = 0;
    while (run_idx < forward_applied.retired_run_count) : (run_idx += 1) {
        try side_runs.retireRun(graph, forward_applied.retired_runs[run_idx], .fwd);
    }

    run_idx = 0;
    while (run_idx < reverse_applied.retired_run_count) : (run_idx += 1) {
        try side_runs.retireRun(graph, reverse_applied.retired_runs[run_idx], .rev);
    }

    old_source_groups.retire(graph);
    old_destination_groups.retire(graph);
}
