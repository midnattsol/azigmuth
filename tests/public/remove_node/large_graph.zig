const std = @import("std");
const graphz = @import("graphz");
const snapshot_api = @import("snapshot_api.zig");
const testing = std.testing;

test "remove_node_stress: remove hub with 200 incoming edges correctness" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const sender_count: usize = 200;
    var senders: [sender_count]graphz.NodeId = undefined;
    for (0..sender_count) |i| senders[i] = try graph.addNode();
    for (0..sender_count) |i| try graph.addEdge(senders[i], hub, 0, .{});

    try graph.validate();
    try testing.expectEqual(@as(u64, 200), graph.edgeCount());

    _ = try graph.removeNode(hub);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (0..sender_count) |i| {
        try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, senders[i], testing.allocator));
        var it = try snapshot_api.neighbors(graph, senders[i], testing.allocator);
        defer it.deinit();
        const neighbors = try it.materialize(testing.allocator);
        defer testing.allocator.free(neighbors);
        try testing.expectEqual(@as(usize, 0), neighbors.len);
    }
}

test "remove_node_stress: remove node with outgoing to many destinations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 150;
    var targets: [target_count]graphz.NodeId = undefined;
    for (0..target_count) |i| targets[i] = try graph.addNode();
    for (0..target_count) |i| try graph.addEdge(source, targets[i], 0, .{});

    _ = try graph.removeNode(source);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    for (0..target_count) |i| {
        try testing.expectEqual(@as(usize, 0), try snapshot_api.inDegree(graph, targets[i], testing.allocator));
    }
}

test "remove_node_stress: bidirectional edges removed correctly" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, a, 0, .{});
    try graph.addEdge(a, c, 0, .{});
    try graph.addEdge(c, a, 0, .{});

    _ = try graph.removeNode(a);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, b, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_api.inDegree(graph, b, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, c, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_api.inDegree(graph, c, testing.allocator));
}

test "remove_node_stress: remove middle node in chain" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, c, 0, .{});

    _ = try graph.removeNode(b);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, a, testing.allocator));
    var it_a = try snapshot_api.neighbors(graph, a, testing.allocator);
    defer it_a.deinit();
    const a_neighbors = try it_a.materialize(testing.allocator);
    defer testing.allocator.free(a_neighbors);
    try testing.expectEqual(@as(usize, 0), a_neighbors.len);

    try testing.expectEqual(@as(usize, 0), try snapshot_api.inDegree(graph, c, testing.allocator));
    var it_c = try snapshot_api.inNeighbors(graph, c, testing.allocator);
    defer it_c.deinit();
    const c_incoming = try it_c.materialize(testing.allocator);
    defer testing.allocator.free(c_incoming);
    try testing.expectEqual(@as(usize, 0), c_incoming.len);
}

test "remove_node_stress: remove node with self-edge and many others" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var others: [50]graphz.NodeId = undefined;
    for (0..50) |i| others[i] = try graph.addNode();

    try graph.addEdge(node, node, 0, .{});
    for (0..50) |i| try graph.addEdge(node, others[i], 0, .{});
    for (0..50) |i| try graph.addEdge(others[i], node, 0, .{});

    _ = try graph.removeNode(node);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    for (0..50) |i| {
        try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, others[i], testing.allocator));
        try testing.expectEqual(@as(usize, 0), try snapshot_api.inDegree(graph, others[i], testing.allocator));
    }
}

test "remove_node_stress: remove nodes sequentially from large graph" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 50;
    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) try graph.addEdge(nodes[i], nodes[j], 0, .{});
        }
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, node_count * (node_count - 1)), graph.edgeCount());

    for (0..node_count) |i| {
        _ = try graph.removeNode(nodes[i]);
        try graph.validate();
    }

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "remove_node_stress: remove half the nodes from dense graph" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 20;
    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) try graph.addEdge(nodes[i], nodes[j], 0, .{});
        }
    }

    for (0..node_count) |i| {
        if (i % 2 == 0) {
            _ = try graph.removeNode(nodes[i]);
        }
    }
    try graph.validate();

    try testing.expectEqual(@as(u64, 90), graph.edgeCount());
}

test "remove_node_stress: remove node leaves others intact" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(b, c, 0, .{});
    try graph.addEdge(c, a, 0, .{});

    _ = try graph.removeNode(b);
    try graph.validate();

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectError(error.InvalidNode, snapshot_api.neighbors(graph, b, testing.allocator));
}

test "remove_node_stress: removeNode with no edges works" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "remove_node_stress: edgeCount accuracy after removeNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes: [10]graphz.NodeId = .{ try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode() };

    for (0..10) |i| {
        for (0..10) |j| {
            if (i != j) try graph.addEdge(nodes[i], nodes[j], 0, .{});
        }
    }

    try graph.validate();
    const before_remove = graph.edgeCount();
    try testing.expectEqual(@as(u64, 90), before_remove);

    _ = try graph.removeNode(nodes[0]);
    try graph.validate();
    try testing.expectEqual(@as(u64, 72), graph.edgeCount());

    _ = try graph.removeNode(nodes[1]);
    _ = try graph.removeNode(nodes[2]);
    try graph.validate();
    try testing.expectEqual(@as(u64, 42), graph.edgeCount());
}

test "remove_node_stress: removeNode then addEdge to survivor works" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(a, c, 0, .{});

    _ = try graph.removeNode(b);
    try graph.validate();

    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(a, c, 0, .{}));
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "remove_node_stress: graph with many nodes some removed" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 30;
    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i < j) try graph.addEdge(nodes[i], nodes[j], 0, .{});
        }
    }

    for (0..node_count) |i| {
        if (i % 3 == 0) {
            _ = try graph.removeNode(nodes[i]);
        }
    }

    try graph.validate();
    var it = try snapshot_api.neighbors(graph, nodes[1], testing.allocator);
    defer it.deinit();
    const neighbors = try it.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 19), neighbors.len);
}
