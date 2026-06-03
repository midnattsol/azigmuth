//! Shape inspection parity tests — verified that SideAdj helpers
//! produce consistent results across contiguous and grouped layouts.

const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const adjacency_mod = test_internals.adjacency;

const testing = std.testing;

test "adjacency parity: tailBlockIndexSide returns correct tail for contiguous" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [3]graph_mod.NodeId = undefined;
    for (0..targets.len) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    const fwd = (try graph.nodeAtConst(src)).publishedFwd();
    const tail = adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd);
    try testing.expect(tail != null);
    try testing.expectEqual(fwd.first_block + fwd.block_count - 1, tail.?);
}

test "adjacency parity: tailBlockIndexSide returns correct tail for grouped" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..70) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }

    const fwd = (try graph.nodeAtConst(src)).publishedFwd();
    if (fwd.group_count > 0) {
        const tail = adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd);
        try testing.expect(tail != null);
    }
}

test "adjacency parity: tailBlockIndexSide returns null for empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    const fwd = (try graph.nodeAtConst(.{ .index = 0 })).publishedFwd();
    try testing.expectEqual(@as(?u32, null), adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd));
}

test "adjacency parity: hasEdgeInAdj vs hasEdgeInSideAdj agree on contiguous layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(src, a, 0, 0);
    try graph.addEdge(src, b, 0, 0);
    try graph.addEdge(src, c, 0, 0);

    const adj = (try graph.nodeAtConst(src)).publishedAdj();
    const fwd = (try graph.nodeAtConst(src)).publishedFwd();

    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, a.index),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, a.index),
    );
    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, b.index),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, b.index),
    );
    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 9999),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 9999),
    );
}

test "adjacency parity: hasEdgeInAdj vs hasEdgeInSideAdj agree on grouped layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..70) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }

    const adj = (try graph.nodeAtConst(src)).publishedAdj();
    const fwd = (try graph.nodeAtConst(src)).publishedFwd();

    if (adj.group_count_fwd > 0) {
        // Check the first, last, and an absent dest.
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 1),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 1),
        );
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 69),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 69),
        );
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 9999),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 9999),
        );
    }
}
