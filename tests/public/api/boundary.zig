const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

test "addEdge with NodeId from a different graph returns InvalidNode when index is out of bounds" {
    var graph_a = try graphz.Graph.init(testing.allocator);
    defer graph_a.deinit();

    const node_in_a = try graph_a.addNode();

    var graph_b = try graphz.Graph.init(testing.allocator);
    defer graph_b.deinit();

    // graph_b has fewer nodes than node_in_a.index, so the NodeId is out of bounds.
    try testing.expectError(error.InvalidNode, graph_b.addEdge(node_in_a, .{ .index = 0 }, 0, .{}));
    try testing.expectError(error.InvalidNode, graph_b.addEdge(.{ .index = 0 }, node_in_a, 0, .{}));

    // graph_b should be untouched.
    try testing.expectEqual(@as(u64, 0), graph_b.edgeCount());
    try graph_b.validate();
}

test "addEdge with NodeId from a different graph succeeds when index happens to be valid" {
    var graph_a = try graphz.Graph.init(testing.allocator);
    defer graph_a.deinit();

    _ = try graph_a.addNode(); // index 0
    _ = try graph_a.addNode(); // index 1
    const node_in_a = try graph_a.addNode(); // index 2

    var graph_b = try graphz.Graph.init(testing.allocator);
    defer graph_b.deinit();

    // Create exactly the same number of nodes so index 0 and 2 are valid.
    const node0_in_b = try graph_b.addNode(); // index 0
    _ = try graph_b.addNode(); // index 1
    const node2_in_b = try graph_b.addNode(); // index 2

    // Trying to add an edge using node_in_a (index 2) as source - the index is valid
    // in graph_b but refers to a different logical node. This is API misuse.
    // The implementation will treat it as node2_in_b.
    try graph_b.addEdge(node_in_a, node0_in_b, 0, .{});
    try graph_b.validate();

    // Verify the edge was added using the index, not the original node identity.
    try testing.expectEqual(@as(u64, 1), graph_b.edgeCount());
    var snapshot = try graph_b.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 1), try snapshot.outDegree(node2_in_b));
}

test "addEdge with NodeId beyond node count returns InvalidNode even if graph has nodes" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    _ = try graph.addNode();

    try testing.expectError(error.InvalidNode, graph.addEdge(.{ .index = 99 }, .{ .index = 0 }, 0, .{}));
    try testing.expectError(error.InvalidNode, graph.addEdge(.{ .index = 0 }, .{ .index = 99 }, 0, .{}));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "NodeId with zero index is valid after addNode called at least once" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    var snapshot = try graph.snapshot(testing.allocator);
    defer snapshot.deinit();
    var neighbors = try snapshot.neighbors(.{ .index = 0 });
    try testing.expect(neighbors.next() == null);
    // Node 0 is valid - no error.
    try testing.expect(graph.hasNode(.{ .index = 0 }));
}
