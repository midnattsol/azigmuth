const std = @import("std");
const graph_mod = @import("graph_mod");
const publish = @import("publish");
const testing = std.testing;

test "removeNode multigraph corruption: reverse multiplicity exceeding forward is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    try graph.addEdge(source, target, 1, 0);

    const target_adj = try graph.publishedNodeAdj(target);
    if (target_adj.block_count_rev > 0 and target_adj.group_count_rev == 0) {
        try publish.appendReverseSource(&graph, target, target_adj, source.index);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

test "removeNode multigraph corruption: reverse multiplicity below forward is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    try graph.addEdge(source, target, 1, 0);

    const target_adj = try graph.publishedNodeAdj(target);
    if (target_adj.block_count_rev > 0 and target_adj.group_count_rev == 0) {
        try publish.writeReverseSource(&graph, target_adj, 0, graph.graph.publishedNodeCount() + 10);
        try publish.truncateReverseByOne(&graph, target, target_adj);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

test "removeNode multigraph corruption: corrupt self-edge multiplicity is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);
    try graph.addEdge(node, node, 1, 0);

    const adj = try graph.publishedNodeAdj(node);
    if (adj.block_count_rev > 0 and adj.group_count_rev == 0) {
        try publish.appendReverseSource(&graph, node, adj, node.index);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(node));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}
