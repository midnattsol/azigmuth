//! CSR materialization: detached flat-array copy of a snapshot's forward
//! adjacency. The CsrView must survive snapshot (and graph) teardown and
//! must exclude tombstoned/removed destinations.

const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "csr: materialized view matches the snapshot and survives its deinit" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

    try graph.addEdge(nodes[0], nodes[1], 0, 0);
    try graph.addEdge(nodes[0], nodes[3], 0, 0);
    try graph.addEdge(nodes[1], nodes[2], 0, 0);
    try graph.addEdge(nodes[4], nodes[0], 0, 0);

    const ctx: graph_mod.algorithms_context_mod.Context = .{ .allocator = testing.allocator };
    var view = blk: {
        var snapshot = try graph.snapshot(ctx);
        defer snapshot.deinit();
        break :blk try snapshot.materializeCsr(ctx);
    };
    defer view.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), view.nodeCount());
    try testing.expectEqual(@as(u64, 4), view.edgeCount());

    const n0 = try view.outNeighbors(nodes[0]);
    try testing.expectEqual(@as(usize, 2), n0.len);
    try testing.expectEqual(nodes[1].index, n0[0]);
    try testing.expectEqual(nodes[3].index, n0[1]);

    try testing.expectEqual(@as(usize, 1), (try view.outNeighbors(nodes[1])).len);
    try testing.expectEqual(@as(usize, 0), (try view.outNeighbors(nodes[2])).len);
    try testing.expectEqual(nodes[0].index, (try view.outNeighbors(nodes[4]))[0]);
    try testing.expectEqual(@as(usize, 2), try view.outDegree(nodes[0]));
    try testing.expect(view.isLive(nodes[2]));
}

test "csr: removed nodes are excluded as sources and destinations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

    try graph.addEdge(nodes[0], nodes[1], 0, 0);
    try graph.addEdge(nodes[0], nodes[2], 0, 0);
    try graph.addEdge(nodes[1], nodes[3], 0, 0);
    _ = try graph.removeNode(nodes[1]);

    const ctx: graph_mod.algorithms_context_mod.Context = .{ .allocator = testing.allocator };
    var view = blk: {
        var snapshot = try graph.snapshot(ctx);
        defer snapshot.deinit();
        break :blk try snapshot.materializeCsr(ctx);
    };
    defer view.deinit(testing.allocator);

    // The tombstoned destination disappears from node 0's row...
    const n0 = try view.outNeighbors(nodes[0]);
    try testing.expectEqual(@as(usize, 1), n0.len);
    try testing.expectEqual(nodes[2].index, n0[0]);

    // ...and the removed source contributes an empty, non-live row.
    try testing.expect(!view.isLive(nodes[1]));
    try testing.expectError(error.InvalidNode, view.outNeighbors(nodes[1]));
    try testing.expectEqual(@as(u64, 1), view.edgeCount());
}
