const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const dfs_mod = test_internals.dfs;

test "dfs visits all reachable nodes from start" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..5) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[0], nodes[2], 0, 0);
    try builder.addEdge(nodes[1], nodes[3], 0, 0);
    try builder.addEdge(nodes[2], nodes[4], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfs_mod.dfs(&graph.graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0), order[0].index);

    var found = std.AutoHashMap(usize, void).init(std.testing.allocator);
    defer found.deinit();
    for (order) |node| try found.put(node.index, {});
    try std.testing.expectEqual(@as(usize, 5), found.count());
    for (0..5) |index| try std.testing.expect(found.contains(index));
}

test "dfs on unconnected graph visits only reachable component" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..4) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[2], nodes[3], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfs_mod.dfs(&graph.graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0].index == 0);
    try std.testing.expect(order[1].index == 1);
}

test "dfs on a graph with a cycle still terminates" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[1], nodes[2], 0, 0);
    try builder.addEdge(nodes[2], nodes[0], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfs_mod.dfs(&graph.graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 3), order.len);
    var found = std.AutoHashMap(usize, void).init(std.testing.allocator);
    defer found.deinit();
    for (order) |node| try found.put(node.index, {});
    try std.testing.expectEqual(@as(usize, 3), found.count());
}

test "dfs returns error on invalid start node" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [1]graph_mod.NodeId = undefined;
    for (0..1) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, dfs_mod.dfs(&graph.graph, .{ .index = 99 }, std.testing.allocator));
}

test "dfs returns error on removed start node" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    _ = try graph.addNode();
    try graph.removeNode(start);

    try std.testing.expectError(error.InvalidNode, dfs_mod.dfs(&graph.graph, start, std.testing.allocator));
}

test "dfs from isolated node returns only the start node" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfs_mod.dfs(&graph.graph, .{ .index = 2 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expectEqual(@as(u32, 2), order[0].index);
}

test "dfs handles self-loop without revisiting the node" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [2]graph_mod.NodeId = undefined;
    for (0..2) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[0], 0, 0);
    try builder.addEdge(nodes[0], nodes[1], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfs_mod.dfs(&graph.graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
}

test "dfs visits neighbors across multiple edge blocks" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..70) |_| {
        const target = try graph.addNode();
        try graph.addEdge(source, target, 0, 0);
    }

    const order = try dfs_mod.dfs(&graph.graph, source, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 71), order.len);
}

test "dfs on empty graph returns InvalidNode" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, dfs_mod.dfs(&graph.graph, .{ .index = 0 }, std.testing.allocator));
}
