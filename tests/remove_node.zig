const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;

const testing = std.testing;

test "removeNode: returns UnsupportedOperation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try testing.expectError(error.UnsupportedOperation, graph.removeNode(node));
}

test "removeNode: returns UnsupportedOperation even with edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    try testing.expectError(error.UnsupportedOperation, graph.removeNode(source));
    try testing.expectError(error.UnsupportedOperation, graph.removeNode(target));
}

test "removeNode: returns InvalidNode for out-of-bounds index" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    try testing.expectError(error.InvalidNode, graph.removeNode(.{ .index = 999 }));
}
