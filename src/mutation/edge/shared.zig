const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_publication_mod = @import("../../storage/node/publication.zig");
const node_adjacency_buffers_mod = @import("../../storage/node/adjacency_buffers.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const side_segments = @import("../../adjacency/segments.zig");
const common = @import("../common.zig");
const node_validity = @import("../../core/node_validity.zig");

pub const PreparedAppendBlock = struct {
    old_block: ?u32 = null,
    new_block: u32,
    tail_idx: ?u32 = null,
};

pub const AppliedAppend = struct {
    block_idx: u32,
    retire_prepared_old_block: bool = true,
    retired_segments: [2]side_segments.SegmentDesc = undefined,
    retired_segment_count: u2 = 0,
};

pub const OldSegmentSlots = struct {
    first_segment: ?u32 = null,
    segment_count: u16 = 0,

    /// Captures the current segmented segment descriptor chain so it can be retired after publish.
    pub fn captureSide(side_adj: *const types.SideAdj) OldSegmentSlots {
        return .{
            .first_segment = if (side_adj.segment_count > 0) side_adj.first_segment else null,
            .segment_count = side_adj.segment_count,
        };
    }

    /// Retires the previously captured segmented segment descriptor chain, if any.
    pub fn retire(self: OldSegmentSlots, graph: *graph_core.GraphCore) void {
        if (self.first_segment) |first_segment| {
            common.retireSegmentSlots(graph, first_segment, self.segment_count);
        }
    }
};

pub const EndpointState = struct {
    source_publication_cell: *node_publication_mod.NodePublicationCell,
    destination_publication_cell: *node_publication_mod.NodePublicationCell,
    source_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers,
    destination_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers,
    claims: common.ClaimedAdjacencies,
    source_state: types.NodePublicationState,
    destination_state: types.NodePublicationState,
    source_flags: types.NodeFlags,
    destination_flags: types.NodeFlags,
};

/// Claims both endpoint adjacencies for an edge mutation and snapshots their publication state.
/// Fails with error.InvalidNode when either endpoint is absent or already removed.
pub fn claimEndpoints(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
) !EndpointState {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) {
        return error.InvalidNode;
    }

    const source_publication_cell = page_ops.nodePublicationAt(graph, source);
    const destination_publication_cell = page_ops.nodePublicationAt(graph, destination);
    // addNode guarantees published pages for every published node.
    const source_buffers = page_ops.nodeAdjacencyBuffersAt(graph, source);
    const destination_buffers = if (source.index == destination.index) source_buffers else page_ops.nodeAdjacencyBuffersAt(graph, destination);
    var claims = try common.tryClaimAdjacencies(graph, source.index, destination.index);
    errdefer claims.release();

    const source_state = node_access.loadPublicationStateAtConst(graph, source);
    const destination_state = node_access.loadPublicationStateAtConst(graph, destination);
    if (source_state.removed or destination_state.removed) return error.InvalidNode;

    return .{
        .source_publication_cell = source_publication_cell,
        .source_buffers = source_buffers,
        .destination_publication_cell = destination_publication_cell,
        .destination_buffers = destination_buffers,
        .claims = claims,
        .source_state = source_state,
        .destination_state = destination_state,
        .source_flags = source_state.flags(),
        .destination_flags = destination_state.flags(),
    };
}

/// Publishes staging data for a newly added edge on both endpoints.
/// `sorted_fwd` / `sorted_rev` describe whether the NEW side layouts remain
/// globally sorted (see addEdgeImpl's appendKeepsGloballySorted).
pub fn publishAdded(
    endpoints: *const EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
    sorted_fwd: bool,
    sorted_rev: bool,
) void {
    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(endpoints.source_state)) == @as(u64, @bitCast(endpoints.destination_state)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(endpoints.source_publication_cell, endpoints.source_buffers, endpoints.source_state, merged_flags, 1, 1, sorted_fwd, sorted_rev);
        return;
    }

    _ = common.publishStagedRev(endpoints.destination_publication_cell, endpoints.destination_buffers, endpoints.destination_state, destination_publish_adj.flags.needs_repair_rev, 1, sorted_rev);
    _ = common.publishStagedFwd(endpoints.source_publication_cell, endpoints.source_buffers, endpoints.source_state, source_publish_adj.flags.needs_repair_fwd, 1, sorted_fwd);
}

/// Retires superseded blocks, segments, and segment chains after addEdge publication.
pub fn retireAdded(
    graph: *graph_core.GraphCore,
    forward_prepared: PreparedAppendBlock,
    forward_applied: AppliedAppend,
    reverse_prepared: PreparedAppendBlock,
    reverse_applied: AppliedAppend,
    old_source_segments: OldSegmentSlots,
    old_destination_segments: OldSegmentSlots,
) !void {
    if (forward_applied.retire_prepared_old_block) {
        if (forward_prepared.old_block) |old_block| try rcu.retireBlockFwd(graph, old_block);
    }
    if (reverse_applied.retire_prepared_old_block) {
        if (reverse_prepared.old_block) |old_block| try rcu.retireBlockRev(graph, old_block);
    }

    var segment_idx: u2 = 0;
    while (segment_idx < forward_applied.retired_segment_count) : (segment_idx += 1) {
        try side_segments.retireSegment(graph, forward_applied.retired_segments[segment_idx], .fwd);
    }

    segment_idx = 0;
    while (segment_idx < reverse_applied.retired_segment_count) : (segment_idx += 1) {
        try side_segments.retireSegment(graph, reverse_applied.retired_segments[segment_idx], .rev);
    }

    old_source_segments.retire(graph);
    old_destination_segments.retire(graph);
}
