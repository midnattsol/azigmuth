const node_access = @import("../core/node_access.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_published_mod = @import("../storage/node/published.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");

fn mirrorPublishedMeta(node: *types.NodeBuffer, meta: types.PublishedMeta) void {
    node.storePublishedMeta(meta);
}

pub fn publishStagedFwd(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, delta: i23) types.PublishedMeta {
    node_published.stagingFwd(expected_meta).* = node.stagingFwd(expected_meta).*;
    var expected = expected_meta;
    while (true) {
        const new_degree: u32 = @intCast(@as(i64, @intCast(node_published.publishedFwdDegreeFromMeta(expected))) + delta);
        node_published.stagingFwdDegree(expected).* = new_degree;
        const desired = types.NodeBuffer.desiredMetaForPublishFwd(expected, needs_repair_fwd or expected.needs_repair_fwd, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse {
            mirrorPublishedMeta(node, desired);
            return desired;
        };
        expected = actual;
    }
}

pub fn publishStagedRev(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_rev: bool, delta: i23) types.PublishedMeta {
    node_published.stagingRev(expected_meta).* = node.stagingRev(expected_meta).*;
    var expected = expected_meta;
    while (true) {
        const new_degree: u32 = @intCast(@as(i64, @intCast(node_published.publishedRevDegreeFromMeta(expected))) + delta);
        node_published.stagingRevDegree(expected).* = new_degree;
        const desired = types.NodeBuffer.desiredMetaForPublishRev(expected, needs_repair_rev or expected.needs_repair_rev, new_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse {
            mirrorPublishedMeta(node, desired);
            return desired;
        };
        expected = actual;
    }
}

pub fn publishStagedBoth(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32) types.PublishedMeta {
    node_published.stagingFwd(expected_meta).* = node.stagingFwd(expected_meta).*;
    node_published.stagingRev(expected_meta).* = node.stagingRev(expected_meta).*;
    node_published.stagingFwdDegree(expected_meta).* = fwd_degree;
    node_published.stagingRevDegree(expected_meta).* = rev_degree;
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishBoth(expected, flags, fwd_degree, rev_degree);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse {
            mirrorPublishedMeta(node, desired);
            return desired;
        };
        expected = actual;
    }
}

pub fn publishBothDelta(node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_delta: i23, rev_delta: i23) types.PublishedMeta {
    node_published.stagingFwd(expected_meta).* = node.stagingFwd(expected_meta).*;
    node_published.stagingRev(expected_meta).* = node.stagingRev(expected_meta).*;
    var expected = expected_meta;
    while (true) {
        const new_fwd: u32 = @intCast(@as(i64, @intCast(node_published.publishedFwdDegreeFromMeta(expected))) + fwd_delta);
        const new_rev: u32 = @intCast(@as(i64, @intCast(node_published.publishedRevDegreeFromMeta(expected))) + rev_delta);
        node_published.stagingFwdDegree(expected).* = new_fwd;
        node_published.stagingRevDegree(expected).* = new_rev;
        var merged_flags = flags;
        merged_flags.needs_repair_fwd = merged_flags.needs_repair_fwd or expected.needs_repair_fwd;
        merged_flags.needs_repair_rev = merged_flags.needs_repair_rev or expected.needs_repair_rev;
        merged_flags.removed = merged_flags.removed or expected.removed;
        const desired = types.NodeBuffer.desiredMetaForPublishBoth(expected, merged_flags, new_fwd, new_rev);
        const actual = node_meta.cmpxchgPublishedMeta(expected, desired) orelse {
            mirrorPublishedMeta(node, desired);
            return desired;
        };
        expected = actual;
    }
}

pub fn publishMetaFwdUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_fwd: bool) types.PublishedMeta {
    return publishMetaFwdDeltaUpdated(graph, node_id, node_meta, node_published, node, expected_meta, needs_repair_fwd, 1);
}

pub fn publishMetaFwdDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_meta);
    return publishStagedFwd(node_meta, node_published, node, expected_meta, needs_repair_fwd, -@as(i23, @intCast(delta)));
}

pub fn publishMetaRevDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_rev: bool, delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingRev(graph, node_id, expected_meta);
    return publishStagedRev(node_meta, node_published, node, expected_meta, needs_repair_rev, -@as(i23, @intCast(delta)));
}

pub fn publishMetaBothDeltaUpdated(graph: *graph_core.GraphCore, node_id: types.NodeId, node_meta: *node_meta_mod.NodeMeta, node_published: *node_published_mod.NodePublished, node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_delta: u22, rev_delta: u22) types.PublishedMeta {
    node_access.copyPublishedToStagingFwd(graph, node_id, expected_meta);
    node_access.copyPublishedToStagingRev(graph, node_id, expected_meta);
    return publishBothDelta(node_meta, node_published, node, expected_meta, flags, -@as(i23, @intCast(fwd_delta)), -@as(i23, @intCast(rev_delta)));
}
