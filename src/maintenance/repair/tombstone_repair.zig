const std = @import("std");
const claims = @import("claims.zig");
const tombstones = @import("tombstones.zig");
const cleanup_mod = @import("cleanup.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");

pub fn compactForwardTombstones(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
) !usize {
    const published_adj = node_access.publishedAdjAtConst(graph, node);
    if (published_adj.block_count_fwd == 0) return 0;

    var tombstone_destinations: std.ArrayList(u32) = .empty;
    defer tombstone_destinations.deinit(graph.allocator);
    try tombstones.collectForwardTombstones(graph, published_adj, &tombstone_destinations);
    if (tombstone_destinations.items.len == 0) return 0;

    var writer_guard = claims.beginWriter(graph);
    defer writer_guard.end();

    var allocs = mutation_common.MutationScratch{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const source_adj_before = node_access.publishedAdjAtConst(graph, node);
    var source_result = try cleanup_mod.rebuildForwardAlive(graph, node.index, source_adj_before, &allocs);
    defer source_result.dropped_prop_rows.deinit(graph.allocator);

    allocs.disarm();

    const preserved_rev = node_access.publishedRevDegreeAtConst(graph, node);
    const new_fwd: u32 = @intCast(source_result.alive_after);
    const node_adjacency_buffers = page_ops.nodeAdjacencyBuffersAt(graph, node);
    // The forward side was rebuilt sorted; the reverse side is untouched.
    const sorted_rev = node_adjacency_buffers.publishedRevSortedFromState(node_access.loadPublicationStateAtConst(graph, node));
    side_adj.publishBothAdj(graph, node, page_ops.nodePublicationAt(graph, node), node_adjacency_buffers, source_result.staging_adj, new_fwd, preserved_rev, true, sorted_rev);
    try side_adj.retireSide(graph, source_adj_before, .fwd);
    for (source_result.dropped_prop_rows.items) |row| rcu.retirePropRow(graph, row);

    return 1;
}
