const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;

const testing = std.testing;

test "GraphBuilder: build empty graph" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "GraphBuilder: build graph with nodes and edges" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const middle = try builder.addNode();
    const target = try builder.addNode();

    try builder.addEdge(source, middle, 1, 0);
    try builder.addEdge(middle, target, 2, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(target));
    try graph.validate();
}

test "GraphBuilder: duplicate edge returns EdgeAlreadyExists" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();

    try builder.addEdge(source, destination, 0, 0);
    try testing.expectError(error.EdgeAlreadyExists, builder.addEdge(source, destination, 0, 0));
}

test "GraphBuilder: deinit after freeze is safe" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);

    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();

    builder.deinit();
}

test "GraphBuilder: frozen graph passes validation and algorithms" {
    const test_internals_bfs = test_internals.bfs;

    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const node0 = try builder.addNode();
    const node1 = try builder.addNode();
    const node2 = try builder.addNode();
    const node3 = try builder.addNode();

    try builder.addEdge(node0, node1, 0, 0);
    try builder.addEdge(node0, node2, 0, 0);
    try builder.addEdge(node1, node3, 0, 0);
    try builder.addEdge(node2, node3, 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();

    const bfs_order = try test_internals_bfs.bfs(&graph.graph, node0, testing.allocator);
    defer testing.allocator.free(bfs_order);
    try testing.expect(bfs_order.len >= 4);
}

test "GraphBuilder: addEdge with non-existent source returns InvalidNode" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const destination = try builder.addNode();
    const dangling_node = graph_mod.NodeId{ .index = 999 };

    try testing.expectError(error.InvalidNode, builder.addEdge(dangling_node, destination, 0, 0));
    try testing.expectError(error.InvalidNode, builder.addEdge(destination, dangling_node, 0, 0));
}

test "GraphBuilder: addEdge with self-loop works correctly" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const node = try builder.addNode();
    try builder.addEdge(node, node, 7, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(node));
}
