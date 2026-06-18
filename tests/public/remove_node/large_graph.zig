const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

test "remove_node_stress: remove hub with 200 incoming edges correctness" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const sender_count: usize = 200;
    var senders: [sender_count]azigmuth.NodeId = undefined;
    for (0..sender_count) |sender_idx| senders[sender_idx] = try graph.addNode();
    for (0..sender_count) |sender_idx| try graph.addEdge(senders[sender_idx], hub, 0, .{});

    try graph.validate();
    try testing.expectEqual(@as(u64, 200), graph.edgeCount());

    _ = try graph.removeNode(hub);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (0..sender_count) |sender_idx| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, senders[sender_idx], testing.allocator));
        var it = try snapshot_support.neighbors(graph, senders[sender_idx], testing.allocator);
        defer it.deinit();
        const neighbors = try it.materialize(testing.allocator);
        defer testing.allocator.free(neighbors);
        try testing.expectEqual(@as(usize, 0), neighbors.len);
    }
}

test "remove_node_stress: remove node with outgoing to many destinations" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 150;
    var targets: [target_count]azigmuth.NodeId = undefined;
    for (0..target_count) |target_idx| targets[target_idx] = try graph.addNode();
    for (0..target_count) |target_idx| try graph.addEdge(source, targets[target_idx], 0, .{});

    _ = try graph.removeNode(source);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    for (0..target_count) |target_idx| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, targets[target_idx], testing.allocator));
    }
}

test "remove_node_stress: bidirectional edges removed correctly" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const other = try graph.addNode();

    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(destination, source, 0, .{});
    try graph.addEdge(source, other, 0, .{});
    try graph.addEdge(other, source, 0, .{});

    _ = try graph.removeNode(source);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, destination, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, destination, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, other, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, other, testing.allocator));
}

test "remove_node_stress: remove middle node in chain" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const middle = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, middle, 0, .{});
    try graph.addEdge(middle, destination, 0, .{});

    _ = try graph.removeNode(middle);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, source, testing.allocator));
    var source_iter = try snapshot_support.neighbors(graph, source, testing.allocator);
    defer source_iter.deinit();
    const source_neighbors = try source_iter.materialize(testing.allocator);
    defer testing.allocator.free(source_neighbors);
    try testing.expectEqual(@as(usize, 0), source_neighbors.len);

    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, destination, testing.allocator));
    var destination_iter = try snapshot_support.inNeighbors(graph, destination, testing.allocator);
    defer destination_iter.deinit();
    const destination_incoming = try destination_iter.materialize(testing.allocator);
    defer testing.allocator.free(destination_incoming);
    try testing.expectEqual(@as(usize, 0), destination_incoming.len);
}

test "remove_node_stress: remove node with self-edge and many others" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var others: [50]azigmuth.NodeId = undefined;
    for (0..50) |other_idx| others[other_idx] = try graph.addNode();

    try graph.addEdge(node, node, 0, .{});
    for (0..50) |other_idx| try graph.addEdge(node, others[other_idx], 0, .{});
    for (0..50) |other_idx| try graph.addEdge(others[other_idx], node, 0, .{});

    _ = try graph.removeNode(node);
    try graph.validate();

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    for (0..50) |other_idx| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, others[other_idx], testing.allocator));
        try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, others[other_idx], testing.allocator));
    }
}

test "remove_node_stress: remove nodes sequentially from large graph" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 50;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |source_idx| nodes[source_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{});
        }
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, node_count * (node_count - 1)), graph.edgeCount());

    for (0..node_count) |node_idx| {
        _ = try graph.removeNode(nodes[node_idx]);
        try graph.validate();
    }

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "remove_node_stress: remove half the nodes from dense graph" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 20;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{});
        }
    }

    for (0..node_count) |node_idx| {
        if (node_idx % 2 == 0) {
            _ = try graph.removeNode(nodes[node_idx]);
        }
    }
    try graph.validate();

    try testing.expectEqual(@as(u64, 90), graph.edgeCount());
}

test "remove_node_stress: remove node leaves others intact" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const removed = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, removed, 0, .{});
    try graph.addEdge(removed, destination, 0, .{});
    try graph.addEdge(destination, source, 0, .{});

    _ = try graph.removeNode(removed);
    try graph.validate();

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectError(error.InvalidNode, snapshot_support.neighbors(graph, removed, testing.allocator));
}

test "remove_node_stress: removeNode with no edges works" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "remove_node_stress: edgeCount accuracy after removeNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes: [10]azigmuth.NodeId = .{ try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode(), try graph.addNode() };

    for (0..10) |source_idx| {
        for (0..10) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{});
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
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const removed = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, removed, 0, .{});
    try graph.addEdge(source, destination, 0, .{});

    _ = try graph.removeNode(removed);
    try graph.validate();

    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destination, 0, .{}));
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "remove_node_stress: graph with many nodes some removed" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 30;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx < destination_idx) try graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{});
        }
    }

    for (0..node_count) |node_idx| {
        if (node_idx % 3 == 0) {
            _ = try graph.removeNode(nodes[node_idx]);
        }
    }

    try graph.validate();
    var it = try snapshot_support.neighbors(graph, nodes[1], testing.allocator);
    defer it.deinit();
    const neighbors = try it.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 19), neighbors.len);
}
