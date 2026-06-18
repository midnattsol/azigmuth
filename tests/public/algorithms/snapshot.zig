const std = @import("std");
const azigmuth = @import("azigmuth");

test "read snapshot algorithms operate on a sealed captured view" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const middle = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, middle, 0, .{});
    try graph.addEdge(middle, destination, 0, .{});

    var snapshot = try graph.snapshot(.{ .allocator = std.testing.allocator });
    defer snapshot.deinit();

    try graph.addEdge(destination, source, 0, .{});

    try std.testing.expectEqual(@as(usize, 3), snapshot.nodeCount());
    try std.testing.expectEqual(false, try snapshot.hasCycle(.{ .allocator = std.testing.allocator }));

    const bfs_order = try snapshot.bfs(source, .{ .allocator = std.testing.allocator });
    defer std.testing.allocator.free(bfs_order);
    try std.testing.expectEqual(@as(usize, 3), bfs_order.len);

    const dfs_order = try snapshot.dfs(source, .{ .allocator = std.testing.allocator });
    defer std.testing.allocator.free(dfs_order);
    try std.testing.expectEqual(@as(usize, 3), dfs_order.len);

    var latest = try graph.snapshot(.{ .allocator = std.testing.allocator });
    defer latest.deinit();
    try latest.validate();
    try std.testing.expectEqual(true, try latest.hasCycle(.{ .allocator = std.testing.allocator }));
}

test "read snapshot exposes neighbors and degrees from the sealed view" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const other = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, other, 0, .{});
    try graph.addEdge(other, source, 0, .{});

    var snapshot = try graph.snapshot(.{ .allocator = std.testing.allocator });
    defer snapshot.deinit();

    try graph.addEdge(destination, source, 0, .{});

    try std.testing.expectEqual(@as(usize, 2), try snapshot.outDegree(source));
    try std.testing.expectEqual(@as(usize, 1), try snapshot.inDegree(source));

    var out = try snapshot.neighbors(source);
    const out_neighbors = try out.materialize(std.testing.allocator);
    defer std.testing.allocator.free(out_neighbors);
    try std.testing.expectEqual(@as(usize, 2), out_neighbors.len);

    var incoming = try snapshot.inNeighbors(source);
    const in_neighbors = try incoming.materialize(std.testing.allocator);
    defer std.testing.allocator.free(in_neighbors);
    try std.testing.expectEqual(@as(usize, 1), in_neighbors.len);
    try std.testing.expectEqual(other.index, in_neighbors[0].index);

    try snapshot.validate();
}
