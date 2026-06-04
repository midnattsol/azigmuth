const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;

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
    try testing.expectEqual(@as(u22, 0), (try graph.nodeAtConst(b)).loadPublishedMeta().degree_fwd);
    // Tombstone b -> a may remain structural until repair compaction,
    // but it is no longer part of the visible logical edge count.
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var neighbors_b = try graph.neighbors(b);
    const b_slice = try graph_mod.materializeConsuming(&neighbors_b, testing.allocator);
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

test "removeNode: predecessor forward tombstone debt flag IS set immediately" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    try graph.removeNode(target);
    try graph.validate();

    // After removeNode, the source's forward adjacency still contains
    // a tombstoned reference to target (structurally).  That is repair
    // debt and MUST be flagged immediately so repairBudgeted can find it.
    const source_adj = (try graph.nodeAtConst(source)).publishedAdj();
    try testing.expect(source_adj.flags.needs_repair_fwd);

    // The tombstoned edge is excluded from the public logical graph.
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    // repairBudgeted discovers and compacts the tombstone, clearing the flag.
    _ = try graph.repairBudgeted(1);
    try graph.validate();

    const after = (try graph.nodeAtConst(source)).publishedAdj();
    try testing.expect(!after.flags.needs_repair_fwd);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "removeNode: repairNode on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);

    try graph.removeNode(a);
    try testing.expectError(error.InvalidNode, graph.repairNode(a));
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "removeNode: celebrity node (high in-degree) does not corrupt forward/reverse consistency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const celebrity = try graph.addNode();
    var predecesors: [200]graph_mod.NodeId = undefined;
    for (0..200) |i| {
        predecesors[i] = try graph.addNode();
        try graph.addEdge(predecesors[i], celebrity, 0, 0);
    }

    const edge_count_before = graph.edgeCount();
    try testing.expectEqual(@as(u64, 200), edge_count_before);

    try graph.removeNode(celebrity);

    // Celebrity is removed.
    try testing.expect(!graph.hasNode(celebrity));
    try testing.expectError(error.InvalidNode, graph.outDegree(celebrity));
    try testing.expectError(error.InvalidNode, graph.inDegree(celebrity));

    // Every predecessor's forward degree dropped by 1 and has repair debt.
    for (0..200) |i| {
        const deg = try graph.outDegree(predecesors[i]);
        try testing.expectEqual(@as(usize, 0), deg);
        const adj = try graph.publishedNodeAdj(predecesors[i]);
        try testing.expect(adj.flags.needs_repair_fwd);
    }

    // Graph is consistent after removal.
    try graph.validate();

    // Budgeted repair can compact the debt progressively.
    const repaired = try graph.repairBudgeted(50);
    try testing.expect(repaired > 0);

    // All debt can be drained.
    while (true) {
        const n = try graph.repairBudgeted(gl: {
            break :gl std.math.maxInt(usize);
        });
        if (n == 0) break;
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}
