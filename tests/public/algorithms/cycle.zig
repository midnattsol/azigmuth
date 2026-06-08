const std = @import("std");
const graphz = @import("graphz");

fn hasCycleOnGraph(graph: *graphz.Graph, allocator: std.mem.Allocator) !bool {
    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();
    return snapshot.hasCycle(allocator);
}

test "empty graph has no cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "single node without edges has no cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "single node with self-loop has cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const node = try builder.addNode();
    try builder.addEdge(node, node, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "two nodes no cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const a = try builder.addNode();
    const b = try builder.addNode();
    try builder.addEdge(a, b, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "two nodes with cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const a = try builder.addNode();
    const b = try builder.addNode();
    try builder.addEdge(a, b, 0, .{});
    try builder.addEdge(b, a, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "three nodes triangle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [3]graphz.NodeId = undefined;
    for (0..3) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[1], nodes[2], 0, .{});
    try builder.addEdge(nodes[2], nodes[0], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "disconnected graph, one component has cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graphz.NodeId = undefined;
    for (0..4) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});
    try builder.addEdge(nodes[3], nodes[2], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "disconnected graph, no cycles" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graphz.NodeId = undefined;
    for (0..4) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "dag with diamond shape has no cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graphz.NodeId = undefined;
    for (0..4) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle reached after an acyclic prefix is detected" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]graphz.NodeId = undefined;
    for (0..5) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[1], nodes[2], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});
    try builder.addEdge(nodes[3], nodes[1], 0, .{});
    try builder.addEdge(nodes[3], nodes[4], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle detection handles duplicate paths to completed nodes" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]graphz.NodeId = undefined;
    for (0..5) |node_index| nodes[node_index] = try builder.addNode();
    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});
    try builder.addEdge(nodes[3], nodes[4], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle detection ignores removed nodes" {
    var graph = try graphz.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, a, 0, .{});
    _ = try graph.removeNode(a);

    try graph.validate();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle detection handles nodes with more than 64 outgoing edges" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const node_count: u32 = 71;
    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |node_index| nodes[node_index] = try builder.addNode();

    for (1..node_count) |target_index| {
        try builder.addEdge(nodes[0], nodes[target_index], 0, .{});
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try std.testing.expectEqual(@as(u64, 70), graph.edgeCount());
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle detection handles nodes with more than 64 outgoing edges and a self-cycle" {
    var builder = try graphz.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const node_count: u32 = 71;
    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |node_index| nodes[node_index] = try builder.addNode();

    for (1..node_count) |target_index| {
        try builder.addEdge(nodes[0], nodes[target_index], 0, .{});
    }
    try builder.addEdge(nodes[0], nodes[0], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try std.testing.expectEqual(@as(u64, 71), graph.edgeCount());
    try std.testing.expectEqual(true, try hasCycleOnGraph(graph, std.testing.allocator));
}

test "cycle detection with dense hub and many tombstoned sources is correct" {
    var graph = try graphz.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const sender_count: usize = 100;
    var senders: [sender_count]graphz.NodeId = undefined;
    for (0..sender_count) |i| {
        senders[i] = try graph.addNode();
        try graph.addEdge(senders[i], hub, 0, .{});
    }

    for (0..sender_count) |i| {
        if (i % 3 == 0) _ = try graph.removeNode(senders[i]);
    }

    try graph.validate();
    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));

    const visible = try graph.inDegree(hub);
    try std.testing.expect(visible > 0);
    try std.testing.expect(visible < sender_count);
}

test "cycle detection with tombstoned self-loop node returns false" {
    var graph = try graphz.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, a, 0, .{});
    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, c, 0, .{});
    try graph.addEdge(c, a, 0, .{});

    _ = try graph.removeNode(a);
    try graph.validate();

    try std.testing.expectEqual(false, try hasCycleOnGraph(graph, std.testing.allocator));
}
