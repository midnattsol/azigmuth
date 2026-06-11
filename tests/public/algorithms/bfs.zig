const std = @import("std");
const azigmuth = @import("azigmuth");

fn bfsOnGraph(graph: *azigmuth.Graph, start: azigmuth.NodeId, allocator: std.mem.Allocator) ![]azigmuth.NodeId {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.bfs(start, .{ .allocator = allocator });
}

fn idxOf(order: []const azigmuth.NodeId, target: usize) usize {
    for (order, 0..) |node, node_index| if (node.index == target) return node_index;
    unreachable;
}

test "bfs order on a simple graph" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]azigmuth.NodeId = undefined;
    for (0..5) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[4], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try bfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0), order[0].index);
    try std.testing.expect(idxOf(order, 1) < idxOf(order, 3));
    try std.testing.expect(idxOf(order, 2) < idxOf(order, 4));
}

test "bfs distances" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]azigmuth.NodeId = undefined;
    for (0..4) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[2], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try bfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expect(idxOf(order, 1) < idxOf(order, 3));
    try std.testing.expect(idxOf(order, 2) < idxOf(order, 3));
}

test "bfs on unconnected graph visits only reachable component" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]azigmuth.NodeId = undefined;
    for (0..4) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try bfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0].index == 0 and order[1].index == 1);
}

test "bfs returns error on invalid start node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, bfsOnGraph(graph, .{ .index = 99 }, std.testing.allocator));
}

test "bfs returns error on removed start node" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    _ = try graph.addNode();
    _ = try graph.removeNode(start);

    try std.testing.expectError(error.InvalidNode, bfsOnGraph(graph, start, std.testing.allocator));
}

test "bfs from isolated node returns only the start node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]azigmuth.NodeId = undefined;
    for (0..3) |node_index| nodes[node_index] = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try bfsOnGraph(graph, .{ .index = 1 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expectEqual(@as(u32, 1), order[0].index);
}

test "bfs handles self-loop without revisiting the node" {
    var builder = try azigmuth.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [2]azigmuth.NodeId = undefined;
    for (0..2) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[0], 0, .{});
    try builder.addEdge(nodes[0], nodes[1], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const order = try bfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
}

test "bfs visits neighbors across multiple edge blocks" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..70) |_| {
        const target = try graph.addNode();
        try graph.addEdge(source, target, 0, .{});
    }

    const order = try bfsOnGraph(graph, source, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 71), order.len);
}

test "bfs on empty graph returns InvalidNode" {
    var graph = try azigmuth.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(error.InvalidNode, bfsOnGraph(graph, .{ .index = 0 }, std.testing.allocator));
}
