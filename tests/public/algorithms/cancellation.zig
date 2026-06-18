//! Cooperative cancellation of snapshot algorithms via Context.cancel_token.
//! Uses pre-cancelled tokens so the tests stay deterministic: the first
//! cancellation checkpoint inside each algorithm must observe the token.

const std = @import("std");
const azigmuth = @import("azigmuth");

const testing = std.testing;

fn buildChain(graph: *azigmuth.Graph, node_count: usize) ![]azigmuth.NodeId {
    const nodes = try testing.allocator.alloc(azigmuth.NodeId, node_count);
    errdefer testing.allocator.free(nodes);
    for (nodes) |*node| node.* = try graph.addNode();
    for (0..node_count - 1) |node_idx| try graph.addEdge(nodes[node_idx], nodes[node_idx + 1], 0, .{});
    return nodes;
}

test "algorithms: a cancelled token aborts bfs, dfs, and hasCycle with error.Cancelled" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try buildChain(graph, 8);
    defer testing.allocator.free(nodes);

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();

    var token = azigmuth.CancelToken.init();
    token.cancel();
    const ctx = azigmuth.Context{ .allocator = testing.allocator, .cancel_token = &token };

    try testing.expectError(error.Cancelled, snapshot.bfs(nodes[0], ctx));
    try testing.expectError(error.Cancelled, snapshot.dfs(nodes[0], ctx));
    try testing.expectError(error.Cancelled, snapshot.hasCycle(ctx));
}

test "algorithms: an attached but uncancelled token does not change results" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try buildChain(graph, 8);
    defer testing.allocator.free(nodes);

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();

    var token = azigmuth.CancelToken.init();
    const ctx = azigmuth.Context{ .allocator = testing.allocator, .cancel_token = &token };

    const order = try snapshot.bfs(nodes[0], ctx);
    defer testing.allocator.free(order);
    try testing.expectEqual(nodes.len, order.len);
    try testing.expectEqual(nodes[0].index, order[0].index);

    const dfs_order = try snapshot.dfs(nodes[0], ctx);
    defer testing.allocator.free(dfs_order);
    try testing.expectEqual(nodes.len, dfs_order.len);

    try testing.expect(!try snapshot.hasCycle(ctx));
}

test "algorithms: cancelling between calls only affects later calls" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try buildChain(graph, 4);
    defer testing.allocator.free(nodes);

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();

    var token = azigmuth.CancelToken.init();
    const ctx = azigmuth.Context{ .allocator = testing.allocator, .cancel_token = &token };

    const order = try snapshot.bfs(nodes[0], ctx);
    testing.allocator.free(order);

    token.cancel();
    try testing.expectError(error.Cancelled, snapshot.bfs(nodes[0], ctx));
}
