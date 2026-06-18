//! Explicit API semantics — documented behaviour for removed nodes,
//! degree queries, and edge-case API contracts.

const std = @import("std");
const azigmuth = @import("azigmuth");

const testing = std.testing;

test "api semantics: addEdge to removed node returns InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.removeNode(destination);

    try testing.expectError(error.InvalidNode, graph.addEdge(source, destination, 0, .{}));
}

test "api semantics: addEdge from removed node returns InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.removeNode(source);

    try testing.expectError(error.InvalidNode, graph.addEdge(source, destination, 0, .{}));
}

test "api semantics: removeEdge on removed node source returns InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    _ = try graph.removeNode(source);

    try testing.expectError(error.InvalidNode, graph.removeEdge(source, destination));
}

test "api semantics: removeEdge on removed node destination returns InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    _ = try graph.removeNode(destination);

    try testing.expectError(error.InvalidNode, graph.removeEdge(source, destination));
}

test "api semantics: repairNode on removed node returns InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.repairNode(node));
}

test "api semantics: edgeCount returns 0 for empty graph" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "api semantics: nodeCount returns 0 for empty graph" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
}
