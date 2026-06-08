const std = @import("std");
const graphz = @import("graphz");

test "read snapshot algorithms operate on a sealed captured view" {
    var graph = try graphz.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, c, 0, .{});

    var snapshot = try graph.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    try graph.addEdge(c, a, 0, .{});

    try std.testing.expectEqual(@as(usize, 3), snapshot.nodeCount());
    try std.testing.expectEqual(false, try snapshot.hasCycle(std.testing.allocator));

    const bfs_order = try snapshot.bfs(a, std.testing.allocator);
    defer std.testing.allocator.free(bfs_order);
    try std.testing.expectEqual(@as(usize, 3), bfs_order.len);

    const dfs_order = try snapshot.dfs(a, std.testing.allocator);
    defer std.testing.allocator.free(dfs_order);
    try std.testing.expectEqual(@as(usize, 3), dfs_order.len);

    var latest = try graph.snapshot(std.testing.allocator);
    defer latest.deinit();
    try std.testing.expectEqual(true, try latest.hasCycle(std.testing.allocator));
}

test "read snapshot exposes neighbors and degrees from the sealed view" {
    var graph = try graphz.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(a, c, 0, .{});
    try graph.addEdge(c, a, 0, .{});

    var snapshot = try graph.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    try graph.addEdge(b, a, 0, .{});

    try std.testing.expectEqual(@as(usize, 2), try snapshot.outDegree(a));
    try std.testing.expectEqual(@as(usize, 1), try snapshot.inDegree(a));

    var out = try snapshot.neighbors(a);
    const out_neighbors = try out.materialize(std.testing.allocator);
    defer std.testing.allocator.free(out_neighbors);
    try std.testing.expectEqual(@as(usize, 2), out_neighbors.len);

    var incoming = try snapshot.inNeighbors(a);
    const in_neighbors = try incoming.materialize(std.testing.allocator);
    defer std.testing.allocator.free(in_neighbors);
    try std.testing.expectEqual(@as(usize, 1), in_neighbors.len);
    try std.testing.expectEqual(c.index, in_neighbors[0].index);
}
