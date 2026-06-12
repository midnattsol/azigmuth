const std = @import("std");
const azigmuth = @import("azigmuth");

fn dfsOnGraph(graph: *azigmuth.Graph, start: azigmuth.NodeId, allocator: std.mem.Allocator) ![]azigmuth.NodeId {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.dfs(start, .{ .allocator = allocator });
}

fn idxOf(order: []const azigmuth.NodeId, target: usize) usize {
    for (order, 0..) |node, node_idx| {
        if (node.index == target) return node_idx;
    }
    unreachable;
}

test "dfs visits all reachable nodes from start" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]azigmuth.NodeId = undefined;
    for (0..5) |node_idx| nodes[node_idx] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[4], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0), order[0].index);

    var found = std.AutoHashMap(usize, void).init(std.testing.allocator);
    defer found.deinit();
    for (order) |node| try found.put(node.index, {});
    try std.testing.expectEqual(@as(usize, 5), found.count());
    for (0..5) |index| try std.testing.expect(found.contains(index));
}

test "dfs on unconnected graph visits only reachable component" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]azigmuth.NodeId = undefined;
    for (0..4) |node_idx| nodes[node_idx] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0].index == 0);
    try std.testing.expect(order[1].index == 1);
}

test "dfs on a graph with a cycle still terminates" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]azigmuth.NodeId = undefined;
    for (0..3) |node_idx| nodes[node_idx] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[1], nodes[2], 0, .{});
    try builder.addEdge(nodes[2], nodes[0], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 3), order.len);
    var found = std.AutoHashMap(usize, void).init(std.testing.allocator);
    defer found.deinit();
    for (order) |node| try found.put(node.index, {});
    try std.testing.expectEqual(@as(usize, 3), found.count());
}

test "dfs returns actual depth-first visitation order" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]azigmuth.NodeId = undefined;
    for (0..5) |node_idx| nodes[node_idx] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[4], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0), order[0].index);
    try std.testing.expect(idxOf(order, 1) < idxOf(order, 2));
    try std.testing.expect(idxOf(order, 3) < idxOf(order, 2));
}

test "dfs returns error on invalid start node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, dfsOnGraph(graph, .{ .index = 99 }, std.testing.allocator));
}

test "dfs returns error on removed start node" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    _ = try graph.addNode();
    _ = try graph.removeNode(start);

    try std.testing.expectError(error.InvalidNode, dfsOnGraph(graph, start, std.testing.allocator));
}

test "dfs from isolated node returns only the start node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]azigmuth.NodeId = undefined;
    for (0..3) |node_idx| nodes[node_idx] = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 2 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expectEqual(@as(u32, 2), order[0].index);
}

test "dfs handles self-loop without revisiting the node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [2]azigmuth.NodeId = undefined;
    for (0..2) |node_idx| nodes[node_idx] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[0], 0, .{});
    try builder.addEdge(nodes[0], nodes[1], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
}

test "dfs visits neighbors across multiple edge blocks" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..70) |_| {
        const target = try graph.addNode();
        try graph.addEdge(source, target, 0, .{});
    }

    const order = try dfsOnGraph(graph, source, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 71), order.len);
}

test "dfs on empty graph returns InvalidNode" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, dfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator));
}
