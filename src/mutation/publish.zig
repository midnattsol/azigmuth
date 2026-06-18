const std = @import("std");
const node_access = @import("../core/node_access.zig");
const node_publication_mod = @import("../storage/node/publication.zig");
const node_adjacency_buffers_mod = @import("../storage/node/adjacency_buffers.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");

/// Applies a signed delta to a published degree. A negative result means the
/// published state is corrupt (a removal accounted twice); saturate at zero
/// instead of invoking checked-arithmetic UB in release builds. The debug
/// assert keeps the invariant loud during development.
fn applyDegreeDelta(current: u32, delta: i23) u32 {
    const wide = @as(i64, current) + delta;
    std.debug.assert(wide >= 0);
    if (wide < 0) return 0;
    return @intCast(wide);
}

pub fn publishStagedFwd(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, needs_repair_fwd: bool, delta: i23, sorted_fwd: bool) types.NodePublicationState {
    node_adjacency_buffers.stagingFwdSorted(expected_state).* = @intFromBool(sorted_fwd);
    var expected = expected_state;
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_adjacency_buffers.publishedFwdDegreeFromState(expected), delta);
        node_adjacency_buffers.stagingFwdDegree(expected).* = new_degree;
        const desired = node_publication_mod.desiredStateForPublishFwd(expected, needs_repair_fwd or expected.needs_repair_fwd, new_degree);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedRev(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, needs_repair_rev: bool, delta: i23, sorted_rev: bool) types.NodePublicationState {
    node_adjacency_buffers.stagingRevSorted(expected_state).* = @intFromBool(sorted_rev);
    var expected = expected_state;
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_adjacency_buffers.publishedRevDegreeFromState(expected), delta);
        node_adjacency_buffers.stagingRevDegree(expected).* = new_degree;
        const desired = node_publication_mod.desiredStateForPublishRev(expected, needs_repair_rev or expected.needs_repair_rev, new_degree);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedBoth(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32, sorted_fwd: bool, sorted_rev: bool) types.NodePublicationState {
    node_adjacency_buffers.stagingFwdSorted(expected_state).* = @intFromBool(sorted_fwd);
    node_adjacency_buffers.stagingRevSorted(expected_state).* = @intFromBool(sorted_rev);
    node_adjacency_buffers.stagingFwdDegree(expected_state).* = fwd_degree;
    node_adjacency_buffers.stagingRevDegree(expected_state).* = rev_degree;
    var expected = expected_state;
    while (true) {
        const desired = node_publication_mod.desiredStateForPublishBoth(expected, flags, fwd_degree, rev_degree);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishBothDelta(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, flags: types.NodeFlags, fwd_delta: i23, rev_delta: i23, sorted_fwd: bool, sorted_rev: bool) types.NodePublicationState {
    node_adjacency_buffers.stagingFwdSorted(expected_state).* = @intFromBool(sorted_fwd);
    node_adjacency_buffers.stagingRevSorted(expected_state).* = @intFromBool(sorted_rev);
    var expected = expected_state;
    while (true) {
        const new_fwd: u32 = applyDegreeDelta(node_adjacency_buffers.publishedFwdDegreeFromState(expected), fwd_delta);
        const new_rev: u32 = applyDegreeDelta(node_adjacency_buffers.publishedRevDegreeFromState(expected), rev_delta);
        node_adjacency_buffers.stagingFwdDegree(expected).* = new_fwd;
        node_adjacency_buffers.stagingRevDegree(expected).* = new_rev;
        var merged_flags = flags;
        merged_flags.needs_repair_fwd = merged_flags.needs_repair_fwd or expected.needs_repair_fwd;
        merged_flags.needs_repair_rev = merged_flags.needs_repair_rev or expected.needs_repair_rev;
        merged_flags.removed = merged_flags.removed or expected.removed;
        const desired = node_publication_mod.desiredStateForPublishBoth(expected, merged_flags, new_fwd, new_rev);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

/// State-only delta: adjusts the published degree and repair flag via CAS
/// WITHOUT copying staging or flipping the side index. Safe without the side
/// claim because no side storage changes.
pub fn publishStateFwdDeltaNoFlip(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, needs_repair_fwd: bool, delta: i23) types.NodePublicationState {
    var expected = node_publication.loadPublicationState();
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_adjacency_buffers.publishedFwdDegreeFromState(expected), delta);
        const desired = node_publication_mod.desiredStateForUpdateFwd(expected, needs_repair_fwd or expected.needs_repair_fwd, new_degree);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStateRevDeltaNoFlip(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, needs_repair_rev: bool, delta: i23) types.NodePublicationState {
    var expected = node_publication.loadPublicationState();
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_adjacency_buffers.publishedRevDegreeFromState(expected), delta);
        const desired = node_publication_mod.desiredStateForUpdateRev(expected, needs_repair_rev or expected.needs_repair_rev, new_degree);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStateBothDeltaNoFlip(node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, flags: types.NodeFlags, fwd_delta: i23, rev_delta: i23) types.NodePublicationState {
    var expected = node_publication.loadPublicationState();
    while (true) {
        const new_fwd: u32 = applyDegreeDelta(node_adjacency_buffers.publishedFwdDegreeFromState(expected), fwd_delta);
        const new_rev: u32 = applyDegreeDelta(node_adjacency_buffers.publishedRevDegreeFromState(expected), rev_delta);
        var merged_flags = flags;
        merged_flags.needs_repair_fwd = merged_flags.needs_repair_fwd or expected.needs_repair_fwd;
        merged_flags.needs_repair_rev = merged_flags.needs_repair_rev or expected.needs_repair_rev;
        merged_flags.removed = merged_flags.removed or expected.removed;
        const desired = node_publication_mod.desiredStateForUpdateBoth(expected, merged_flags, new_fwd, new_rev);
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStateFwdUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, needs_repair_fwd: bool) types.NodePublicationState {
    return publishStateFwdDeltaUpdated(graph, node_id, node_publication, node_adjacency_buffers, expected_state, needs_repair_fwd, 1);
}

pub fn publishStateFwdDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, needs_repair_fwd: bool, delta: u22) types.NodePublicationState {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_state);
    return publishStagedFwd(node_publication, node_adjacency_buffers, expected_state, needs_repair_fwd, -@as(i23, @intCast(delta)), node_adjacency_buffers.publishedFwdSortedFromState(expected_state));
}

pub fn publishStateRevDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, needs_repair_rev: bool, delta: u22) types.NodePublicationState {
    node_access.copyPublishedToStagingRev(graph, node_id, expected_state);
    return publishStagedRev(node_publication, node_adjacency_buffers, expected_state, needs_repair_rev, -@as(i23, @intCast(delta)), node_adjacency_buffers.publishedRevSortedFromState(expected_state));
}

pub fn publishStateBothDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_publication: *node_publication_mod.NodePublicationCell, node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers, expected_state: types.NodePublicationState, flags: types.NodeFlags, fwd_delta: u22, rev_delta: u22) types.NodePublicationState {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_state);
    node_access.copyPublishedToStagingRev(graph, node_id, expected_state);
    return publishBothDelta(node_publication, node_adjacency_buffers, expected_state, flags, -@as(i23, @intCast(fwd_delta)), -@as(i23, @intCast(rev_delta)), node_adjacency_buffers.publishedFwdSortedFromState(expected_state), node_adjacency_buffers.publishedRevSortedFromState(expected_state));
}
