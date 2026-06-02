const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;

const testing = std.testing;

fn expectRemovedNodeInvalid(graph: *graph_mod.Graph, node: graph_mod.NodeId) !void {
    try testing.expect(!graph.hasNode(node));
    try testing.expectError(error.InvalidNode, graph.neighbors(node));
    try testing.expectError(error.InvalidNode, graph.inNeighbors(node));
    try testing.expectError(error.InvalidNode, graph.outDegree(node));
    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}

test "removeNode: public API invalidates removed node and hides tombstoned incoming edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.addEdge(b, a, 0, 0);

    try graph.removeNode(a);
    try graph.validate();

    try expectRemovedNodeInvalid(&graph, a);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(b));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(c));
    try testing.expectEqual(@as(u16, 0), (try graph.nodeAtConst(b)).degree_fwd);
    // Tombstone b -> a may remain structural until repair compaction,
    // but it is no longer part of the visible logical edge count.
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var neighbors_b = try graph.neighbors(b);
    const b_slice = try neighbors_b.materialize(testing.allocator);
    defer testing.allocator.free(b_slice);
    try testing.expectEqual(@as(usize, 0), b_slice.len);
}

test "removeNode: repairNode compacts tombstoned incoming edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);

    try graph.removeNode(a);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(b));

    try graph.repairNode(b);
    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(b));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const a_adj = page_ops.nodeAtConst(&graph.graph, a).publishedAdj();
    try testing.expectEqual(@as(u16, 0), a_adj.block_count_rev);
}

test "removeNode: self-edge is removed from both forward and reverse state" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    try graph.addEdge(a, a, 0, 0);

    try graph.removeNode(a);
    try graph.validate();
    try expectRemovedNodeInvalid(&graph, a);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const a_adj = page_ops.nodeAtConst(&graph.graph, a).publishedAdj();
    try testing.expectEqual(@as(u16, 0), a_adj.block_count_fwd);
    try testing.expectEqual(@as(u16, 0), a_adj.block_count_rev);
}

test "removeNode: repairBudgeted discovers tombstone debt without explicit repairNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);

    try graph.removeNode(a);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const compacted = try graph.repairBudgeted(1);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(b));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const a_adj = page_ops.nodeAtConst(&graph.graph, a).publishedAdj();
    try testing.expectEqual(@as(u16, 0), a_adj.block_count_rev);
}

test "removeNode: removed endpoints are InvalidNode for edge mutations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);
    try graph.removeNode(a);

    try testing.expectError(error.InvalidNode, graph.addEdge(a, b, 0, 0));
    try testing.expectError(error.InvalidNode, graph.addEdge(b, a, 0, 0));
    try testing.expectError(error.InvalidNode, graph.removeEdge(a, b));
    try testing.expectError(error.InvalidNode, graph.removeEdge(b, a));
}

test "removeNode: repeated removal returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    try graph.removeNode(a);
    try testing.expectError(error.InvalidNode, graph.removeNode(a));
}

test "removeNode: returns InvalidNode for out-of-bounds index" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    try testing.expectError(error.InvalidNode, graph.removeNode(.{ .index = 999 }));
}
