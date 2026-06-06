const std = @import("std");
const claims = @import("claims.zig");
const tombstones = @import("tombstones.zig");
const cleanup_mod = @import("cleanup.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../side_adj.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
pub const ReverseCleanupTarget = struct {
    node_buffer: *types.NodeBuffer,
    published_adj_before: types.NodeAdj,
    staging_adj_after: types.NodeAdj,
    new_degree_rev: u22,
};

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

    var claimed_dest_nodes = try std.ArrayList(*types.NodeBuffer).initCapacity(graph.allocator, tombstone_destinations.items.len);
    defer {
        var remaining = claimed_dest_nodes.items.len;
        while (remaining > 0) {
            remaining -= 1;
            claims.releaseNodeForPublish(claimed_dest_nodes.items[remaining]);
        }
        claimed_dest_nodes.deinit(graph.allocator);
    }

    var reverse_updates = try std.ArrayList(ReverseCleanupTarget).initCapacity(graph.allocator, tombstone_destinations.items.len);
    defer reverse_updates.deinit(graph.allocator);

    for (tombstone_destinations.items) |destination_idx| {
        const destination_node = page_ops.nodeAt(graph, .{ .index = destination_idx });
        try claims.claimNodeForPublish(destination_node);
        claimed_dest_nodes.appendAssumeCapacity(destination_node);
    }

    var writer_guard = claims.beginWriter(graph);
    defer writer_guard.end();

    var allocs = mutation_common.MutationScratch{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const source_adj_before = node_mut.publishedAdj();
    const source_result = try cleanup_mod.rebuildForwardLive(graph, node.index, source_adj_before, &allocs);

    for (tombstone_destinations.items, claimed_dest_nodes.items) |destination_idx, destination_node| {
        const destination_adj_before = destination_node.publishedAdj();
        const reverse_result = try cleanup_mod.rebuildReverseDrop(graph, destination_idx, destination_adj_before, node.index, &allocs);
        try reverse_updates.append(graph.allocator, .{
            .node_buffer = destination_node,
            .published_adj_before = destination_adj_before,
            .staging_adj_after = reverse_result.staging_adj,
            .new_degree_rev = if (destination_adj_before.flags.removed) @as(u22, 0) else @as(u22, @intCast(reverse_result.live_after)),
        });
    }

    allocs.disarm();

    for (reverse_updates.items) |update| {
        const preserved_fwd = update.node_buffer.loadPublishedMeta().degree_fwd;
        side_adj.publishBothAdj(update.node_buffer, update.staging_adj_after, preserved_fwd, update.new_degree_rev);
        try side_adj.retireSide(graph, update.published_adj_before, .rev);
    }

    const preserved_rev = node_mut.loadPublishedMeta().degree_rev;
    const new_fwd: u22 = @as(u22, @intCast(source_result.live_after));
    side_adj.publishBothAdj(node_mut, source_result.staging_adj, new_fwd, preserved_rev);
    try side_adj.retireSide(graph, source_adj_before, .fwd);

    return 1;
}
