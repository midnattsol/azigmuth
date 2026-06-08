const std = @import("std");
const claims = @import("claims.zig");
const tombstones = @import("tombstones.zig");
const cleanup_mod = @import("cleanup.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");

pub fn compactForwardTombstones(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    node_mut: *types.NodeBuffer,
) !usize {
    const published_adj = node_mut.publishedAdj();
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

    const source_adj_before = node_mut.publishedAdj();
    const source_result = try cleanup_mod.rebuildForwardLive(graph, node.index, source_adj_before, &allocs);

    allocs.disarm();

    const preserved_rev = node_mut.loadPublishedMeta().degree_rev;
    const new_fwd: u22 = @as(u22, @intCast(source_result.live_after));
    side_adj.publishBothAdj(node_mut, source_result.staging_adj, new_fwd, preserved_rev);
    try side_adj.retireSide(graph, source_adj_before, .fwd);

    return 1;
}
