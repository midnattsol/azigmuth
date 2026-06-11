const std = @import("std");
const node_access = @import("../core/node_access.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_published_mod = @import("../storage/node/published.zig");
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

pub fn publishStagedFwd(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, delta: i23, fwd_sorted: bool) types.PublishedMeta {
    node_published.stagingFwdSorted(expected_meta).* = @intFromBool(fwd_sorted);
    var expected = expected_meta;
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_published.publishedFwdDegreeFromMeta(expected), delta);
        node_published.stagingFwdDegree(expected).* = new_degree;
        const desired = node_meta_mod.desiredMetaForPublishFwd(expected, needs_repair_fwd or expected.needs_repair_fwd, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedRev(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, needs_repair_rev: bool, delta: i23, rev_sorted: bool) types.PublishedMeta {
    node_published.stagingRevSorted(expected_meta).* = @intFromBool(rev_sorted);
    var expected = expected_meta;
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_published.publishedRevDegreeFromMeta(expected), delta);
        node_published.stagingRevDegree(expected).* = new_degree;
        const desired = node_meta_mod.desiredMetaForPublishRev(expected, needs_repair_rev or expected.needs_repair_rev, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedBoth(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32, fwd_sorted: bool, rev_sorted: bool) types.PublishedMeta {
    node_published.stagingFwdSorted(expected_meta).* = @intFromBool(fwd_sorted);
    node_published.stagingRevSorted(expected_meta).* = @intFromBool(rev_sorted);
    node_published.stagingFwdDegree(expected_meta).* = fwd_degree;
    node_published.stagingRevDegree(expected_meta).* = rev_degree;
    var expected = expected_meta;
    while (true) {
        const desired = node_meta_mod.desiredMetaForPublishBoth(expected, flags, fwd_degree, rev_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishBothDelta(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_delta: i23, rev_delta: i23, fwd_sorted: bool, rev_sorted: bool) types.PublishedMeta {
    node_published.stagingFwdSorted(expected_meta).* = @intFromBool(fwd_sorted);
    node_published.stagingRevSorted(expected_meta).* = @intFromBool(rev_sorted);
    var expected = expected_meta;
    while (true) {
        const new_fwd: u32 = applyDegreeDelta(node_published.publishedFwdDegreeFromMeta(expected), fwd_delta);
        const new_rev: u32 = applyDegreeDelta(node_published.publishedRevDegreeFromMeta(expected), rev_delta);
        node_published.stagingFwdDegree(expected).* = new_fwd;
        node_published.stagingRevDegree(expected).* = new_rev;
        var merged_flags = flags;
        merged_flags.needs_repair_fwd = merged_flags.needs_repair_fwd or expected.needs_repair_fwd;
        merged_flags.needs_repair_rev = merged_flags.needs_repair_rev or expected.needs_repair_rev;
        merged_flags.removed = merged_flags.removed or expected.removed;
        const desired = node_meta_mod.desiredMetaForPublishBoth(expected, merged_flags, new_fwd, new_rev);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

/// Meta-only delta: adjusts the published degree and repair flag via CAS
/// WITHOUT copying staging or flipping the side index. Safe without the side
/// claim because no side storage changes.
pub fn publishMetaFwdDeltaNoFlip(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, needs_repair_fwd: bool, delta: i23) types.PublishedMeta {
    var expected = node_meta.loadPublishedMeta();
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_published.publishedFwdDegreeFromMeta(expected), delta);
        const desired = node_meta_mod.desiredMetaForUpdateFwd(expected, needs_repair_fwd or expected.needs_repair_fwd, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishMetaRevDeltaNoFlip(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, needs_repair_rev: bool, delta: i23) types.PublishedMeta {
    var expected = node_meta.loadPublishedMeta();
    while (true) {
        const new_degree: u32 = applyDegreeDelta(node_published.publishedRevDegreeFromMeta(expected), delta);
        const desired = node_meta_mod.desiredMetaForUpdateRev(expected, needs_repair_rev or expected.needs_repair_rev, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishMetaBothDeltaNoFlip(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, flags: types.NodeFlags, fwd_delta: i23, rev_delta: i23) types.PublishedMeta {
    var expected = node_meta.loadPublishedMeta();
    while (true) {
        const new_fwd: u32 = applyDegreeDelta(node_published.publishedFwdDegreeFromMeta(expected), fwd_delta);
        const new_rev: u32 = applyDegreeDelta(node_published.publishedRevDegreeFromMeta(expected), rev_delta);
        var merged_flags = flags;
        merged_flags.needs_repair_fwd = merged_flags.needs_repair_fwd or expected.needs_repair_fwd;
        merged_flags.needs_repair_rev = merged_flags.needs_repair_rev or expected.needs_repair_rev;
        merged_flags.removed = merged_flags.removed or expected.removed;
        const desired = node_meta_mod.desiredMetaForUpdateBoth(expected, merged_flags, new_fwd, new_rev);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishMetaFwdUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, needs_repair_fwd: bool) types.PublishedMeta {
    return publishMetaFwdDeltaUpdated(graph, node_id, node_meta, node_published, expected_meta, needs_repair_fwd, 1);
}

pub fn publishMetaFwdDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_meta);
    return publishStagedFwd(node_meta, node_published, expected_meta, needs_repair_fwd, -@as(i23, @intCast(delta)), node_published.publishedFwdSortedFromMeta(expected_meta));
}

pub fn publishMetaRevDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, needs_repair_rev: bool, delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingRev(graph, node_id, expected_meta);
    return publishStagedRev(node_meta, node_published, expected_meta, needs_repair_rev, -@as(i23, @intCast(delta)), node_published.publishedRevSortedFromMeta(expected_meta));
}

pub fn publishMetaBothDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_delta: u22, rev_delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_meta);
    node_access.copyPublishedToStagingRev(graph, node_id, expected_meta);
    return publishBothDelta(node_meta, node_published, expected_meta, flags, -@as(i23, @intCast(fwd_delta)), -@as(i23, @intCast(rev_delta)), node_published.publishedFwdSortedFromMeta(expected_meta), node_published.publishedRevSortedFromMeta(expected_meta));
}
