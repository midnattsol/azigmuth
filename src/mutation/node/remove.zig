const graph_core = @import("../../core/graph_core.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const node_access = @import("../../core/node_access.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("../common.zig");
const remove_scan = @import("remove/scan.zig");
const remove_validate = @import("remove/validate.zig");
const remove_plan = @import("remove/plan.zig");
const remove_publish = @import("remove/publish.zig");
const node_validity = @import("../../core/node_validity.zig");

/// Removes one live node and retires both of its published adjacencies.
/// Returns a summary of visible edge removals and related-node updates.
pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !types.NodeRemovalSummary {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    var source_claims = try common.tryClaimNodeSides(graph, node.index, true, true);
    defer source_claims.release();

    const source_adj_before = node_access.publishedAdjAtConst(graph, node);
    if (!node_validity.snapshotIsLive(source_adj_before)) return error.InvalidNode;

    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .fwd);
    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .rev);

    var scan = try remove_scan.scanNodeRemovalNeighborhood(graph, node);
    defer scan.deinit(graph.allocator);

    try remove_validate.validateNodeRemovalNeighborhood(graph, node, &scan);

    var related = try remove_plan.collectRelatedNodeUpdates(graph, node, &scan);
    defer related.deinit(graph.allocator);

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_staging_adj = remove_publish.buildRemovedAdjEmpty(source_adj_before);

    // Publish predecessor-side degree/repair updates before tombstoning the
    // removed node. Readers may therefore observe a transient mixed-version
    // view across endpoints while removeNode is in flight; the operation only
    // guarantees logical consistency after it returns.
    //
    // Forward-degree decrements use the meta-only CAS helper
    // (`publishMetaFwdDeltaUpdated`) which does NOT require `fwd_claim` on the
    // predecessor — the 64-bit CAS on `published_meta` provides the atomicity
    // (RFC §concurrency note).
    const counts = remove_publish.publishRelatedNodeUpdates(graph, related.nodes.items);

    // Edge accounting happens at publish time: a related endpoint that was
    // concurrently removed after the scan already paid for the shared edge.
    const removed_visible_edge_count = counts.applied_edge_removals + scan.self_edge_count;

    common.publishBothAdj(graph, node, page_ops.nodeMetaAt(graph, node), page_ops.nodePublishedAt(graph, node), source_staging_adj, 0, 0, true, true);

    try remove_publish.retireRemovedNodeStorage(graph, source_adj_before);
    // Every forward edge of the removed node dies with it: its property rows
    // recycle once no reader can still observe the retired blocks.
    if (graph.edge_properties_enabled) {
        try side_ops.forEachForwardEntryInSide(graph, side_ops.sideAdjOfNode(source_adj_before, .fwd), graph, struct {
            fn run(inner_graph: *const graph_core.GraphCore, mut_graph: *graph_core.GraphCore, entry: side_ops.ForwardEntryView) !void {
                _ = inner_graph;
                rcu.retirePropRow(mut_graph, entry.prop_row);
            }
        }.run);
    }
    _ = graph.edge_count.fetchSub(@as(u64, @intCast(removed_visible_edge_count)), .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();

    return .{
        .removed_visible_edges = @intCast(removed_visible_edge_count),
        .related_live_nodes_touched = @intCast(related.nodes.items.len),
        .left_repair_debt = counts.predecessors > 0 or counts.destinations > 0,
    };
}
