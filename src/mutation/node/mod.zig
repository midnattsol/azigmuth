//! Node-oriented mutation helpers and node removal implementation.

const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("../common.zig");
const remove_types = @import("remove_types.zig");
const remove_scan = @import("remove_scan.zig");
const remove_validate = @import("remove_validate.zig");
const remove_plan = @import("remove_plan.zig");
const remove_publish = @import("remove_publish.zig");
const node_validity = @import("../../core/node_validity.zig");

pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !types.NodeRemovalSummary {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, node);
    var source_claims = try common.tryClaimNodeSides(source_node, true, true);
    defer source_claims.release();

    const source_adj_before = source_node.publishedAdj();
    if (!node_validity.snapshotIsLive(source_adj_before)) return error.InvalidNode;

    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .fwd);
    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .rev);

    var scan = try remove_scan.scanNodeRemovalNeighborhood(graph, node);
    defer scan.deinit(graph.allocator);

    try remove_validate.validateNodeRemovalNeighborhood(graph, node, source_node, &scan);

    var related = try remove_plan.collectRelatedNodeUpdates(graph, node, &scan);
    defer related.deinit(graph.allocator);

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const removed_visible_edge_count = scan.visible_forward + scan.visible_incoming;

    const source_staging_adj = remove_publish.buildRemovedAdjEmpty(source_adj_before);

    // Publish predecessor-side degree/repair updates before tombstoning the
    // removed node. Readers may therefore observe a transient mixed-version
    // view across endpoints while removeNode is in flight; the operation only
    // guarantees logical consistency after it returns.
    //
    // Forward-degree decrements use the meta-only CAS helper
    // (`publishMetaFwdDeltaUpdated`) which does NOT require `fwd_claim` on the
    // predecessor — the 64-bit CAS on `published_meta` provides the atomicity
    // (RFC Phase 2 §concurrency note).
    const counts = remove_publish.publishRelatedNodeUpdates(related.nodes.items);

    common.publishBothAdj(source_node, source_staging_adj, 0, 0);

    try remove_publish.retireRemovedNodeStorage(graph, source_adj_before);
    _ = graph.edge_count.fetchSub(@as(u64, @intCast(removed_visible_edge_count)), .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();

    return .{
        .removed_visible_edges = @intCast(removed_visible_edge_count),
        .related_live_nodes_touched = @intCast(related.nodes.items.len),
        .left_repair_debt = counts.predecessors > 0 or counts.destinations > 0,
    };
}
