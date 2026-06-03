//! Explicit API semantics — documented behaviour for removed nodes,
//! degree queries, and edge-case API contracts.

const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const helpers = @import("helpers.zig");

const testing = std.testing;

test "api semantics: outDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.outDegree(node));
}

test "api semantics: inDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}

test "api semantics: neighbors on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.neighbors(node));
}

test "api semantics: inNeighbors on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.inNeighbors(node));
}

test "api semantics: hasNode on removed node returns false" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
}

test "api semantics: addEdge to removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.removeNode(dst);

    try testing.expectError(error.InvalidNode, graph.addEdge(src, dst, 0, 0));
}

test "api semantics: addEdge from removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.removeNode(src);

    try testing.expectError(error.InvalidNode, graph.addEdge(src, dst, 0, 0));
}

test "api semantics: removeEdge on removed node source returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try graph.removeNode(src);

    try testing.expectError(error.InvalidNode, graph.removeEdge(src, dst));
}

test "api semantics: removeEdge on removed node destination returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try graph.removeNode(dst);

    try testing.expectError(error.InvalidNode, graph.removeEdge(src, dst));
}

test "api semantics: repairNode on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expectError(error.InvalidNode, graph.repairNode(node));
}

test "api semantics: edgeCount returns 0 for empty graph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "api semantics: nodeCount returns 0 for empty graph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
}

test "api semantics: duplicate addEdge returns EdgeAlreadyExists" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(a, b, 0, 0));
}

test "api semantics: removeEdge on non-existent edge returns false" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    try testing.expectEqual(false, try graph.removeEdge(a, b));
}

test "api semantics: concurrent mutation on claimed adjacency returns ConcurrentMutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const a_node = try graph.nodeAt(a);
    try testing.expectEqual(@as(u8, 0), a_node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer a_node.fwd_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(a, b, 0, 0));
}
