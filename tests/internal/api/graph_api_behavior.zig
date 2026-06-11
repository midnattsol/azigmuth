const std = @import("std");
const graph_mod = @import("graph_mod");

const Graph = graph_mod.Graph;
const testing = std.testing;

test "graph api: query APIs return InvalidNode for out-of-bounds node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();

    try testing.expectError(error.InvalidNode, graph.neighbors(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.inNeighbors(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.outDegree(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.inDegree(.{ .index = 77 }));
}

test "graph api: removed node is absent from public node API" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
    try testing.expectError(error.InvalidNode, graph.nodeAt(node));
    try testing.expectError(error.InvalidNode, graph.publishedNodeAdj(node));
}
