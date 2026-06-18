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

    const removed_node = try graph.addNode();
    const predecessor = try graph.addNode();
    const other_destination = try graph.addNode();
    try graph.addEdge(removed_node, predecessor, 0, 0);
    try graph.addEdge(removed_node, other_destination, 0, 0);
    try graph.addEdge(predecessor, removed_node, 0, 0);

    _ = try graph.removeNode(removed_node);
    try graph.validate();

    try expectRemovedNodeInvalid(&graph, removed_node);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(predecessor));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(other_destination));
    try testing.expectEqual(@as(u22, 0), (try graph.nodeAt(predecessor)).loadPublicationState().degree_fwd);
    // Tombstone predecessor -> removed_node may remain structural until repair compaction,
    // but it is no longer part of the visible logical edge count.
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var predecessor_neighbors = try graph.neighbors(predecessor);
    const predecessor_slice = try graph_mod.materializeConsuming(&predecessor_neighbors, testing.allocator);
    defer testing.allocator.free(predecessor_slice);
    try testing.expectEqual(@as(usize, 0), predecessor_slice.len);
}

test "removeNode: repairNode compacts tombstoned incoming edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, removed_node, 0, 0);

    _ = try graph.removeNode(removed_node);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(predecessor));

    _ = try graph.repairNode(predecessor);
    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(predecessor));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const removed_adj = graph.nodeRefAny(removed_node).publishedAdj();
    try testing.expectEqual(@as(u16, 0), removed_adj.block_count_rev);
}

test "removeNode: self-edge is removed from both forward and reverse state" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    try graph.addEdge(removed_node, removed_node, 0, 0);

    _ = try graph.removeNode(removed_node);
    try graph.validate();
    try expectRemovedNodeInvalid(&graph, removed_node);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const removed_adj = graph.nodeRefAny(removed_node).publishedAdj();
    try testing.expectEqual(@as(u16, 0), removed_adj.block_count_fwd);
    try testing.expectEqual(@as(u16, 0), removed_adj.block_count_rev);
}

test "removeNode: repairBudgeted discovers tombstone debt without explicit repairNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, removed_node, 0, 0);

    _ = try graph.removeNode(removed_node);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const compacted = try graph.repairBudgeted(1);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(predecessor));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    const removed_adj = graph.nodeRefAny(removed_node).publishedAdj();
    try testing.expectEqual(@as(u16, 0), removed_adj.block_count_rev);
}

test "removeNode: removed endpoints are InvalidNode for edge mutations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, removed_node, 0, 0);
    _ = try graph.removeNode(removed_node);

    try testing.expectError(error.InvalidNode, graph.addEdge(removed_node, predecessor, 0, 0));
    try testing.expectError(error.InvalidNode, graph.addEdge(predecessor, removed_node, 0, 0));
    try testing.expectError(error.InvalidNode, graph.removeEdge(removed_node, predecessor));
    try testing.expectError(error.InvalidNode, graph.removeEdge(predecessor, removed_node));
}

test "removeNode: repeated removal returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    _ = try graph.removeNode(removed_node);
    try testing.expectError(error.InvalidNode, graph.removeNode(removed_node));
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

    _ = try graph.removeNode(target);
    try graph.validate();

    // After removeNode, the source's forward adjacency still contains
    // a tombstoned reference to target (structurally).  That is repair
    // debt and MUST be flagged immediately so repairBudgeted can find it.
    const source_adj = try graph.publishedNodeAdj(source);
    try testing.expect(source_adj.flags.needs_repair_fwd);

    // The tombstoned edge is excluded from the public logical graph.
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    // repairBudgeted discovers and compacts the tombstone, clearing the flag.
    _ = try graph.repairBudgeted(1);
    try graph.validate();

    const after = try graph.publishedNodeAdj(source);
    try testing.expect(!after.flags.needs_repair_fwd);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "removeNode: repairNode on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, removed_node, 0, 0);

    _ = try graph.removeNode(removed_node);
    try testing.expectError(error.InvalidNode, graph.repairNode(removed_node));
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "removeNode: celebrity node (high in-degree) does not corrupt forward/reverse consistency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const celebrity = try graph.addNode();
    var predecessors: [200]graph_mod.NodeId = undefined;
    for (0..200) |predecessor_idx| {
        predecessors[predecessor_idx] = try graph.addNode();
        try graph.addEdge(predecessors[predecessor_idx], celebrity, 0, 0);
    }

    const edge_count_before = graph.edgeCount();
    try testing.expectEqual(@as(u64, 200), edge_count_before);

    _ = try graph.removeNode(celebrity);

    // Celebrity is removed.
    try testing.expect(!graph.hasNode(celebrity));
    try testing.expectError(error.InvalidNode, graph.outDegree(celebrity));
    try testing.expectError(error.InvalidNode, graph.inDegree(celebrity));

    // Every predecessor's forward degree dropped by 1 and has repair debt.
    for (0..200) |predecessor_idx| {
        const deg = try graph.outDegree(predecessors[predecessor_idx]);
        try testing.expectEqual(@as(usize, 0), deg);
        const adj = try graph.publishedNodeAdj(predecessors[predecessor_idx]);
        try testing.expect(adj.flags.needs_repair_fwd);
    }

    // Graph is consistent after removal.
    try graph.validate();

    // Budgeted repair can compact the debt progressively.
    const repaired = try graph.repairBudgeted(50);
    try testing.expect(repaired > 0);

    // All debt can be drained.
    while (true) {
        const repaired_now = try graph.repairBudgeted(gl: {
            break :gl std.math.maxInt(usize);
        });
        if (repaired_now == 0) break;
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}
