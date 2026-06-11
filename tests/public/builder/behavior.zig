const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");

const testing = std.testing;

test "GraphBuilder: build empty graph" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "GraphBuilder: build graph with nodes and edges" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const middle = try builder.addNode();
    const target = try builder.addNode();

    try builder.addEdge(source, middle, 1, .{});
    try builder.addEdge(middle, target, 2, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, target, testing.allocator));
    try graph.validate();
}

test "GraphBuilder: duplicate edge returns EdgeAlreadyExists" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();

    try builder.addEdge(source, destination, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, builder.addEdge(source, destination, 0, .{}));
}

test "GraphBuilder: deinit after freeze is safe" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);

    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();

    builder.deinit();
}

test "GraphBuilder: frozen graph passes validation and algorithms" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const node0 = try builder.addNode();
    const node1 = try builder.addNode();
    const node2 = try builder.addNode();
    const node3 = try builder.addNode();

    try builder.addEdge(node0, node1, 0, .{});
    try builder.addEdge(node0, node2, 0, .{});
    try builder.addEdge(node1, node3, 0, .{});
    try builder.addEdge(node2, node3, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const bfs_order = try snapshot.bfs(node0, .{ .allocator = testing.allocator });
    defer testing.allocator.free(bfs_order);
    try testing.expect(bfs_order.len >= 4);
}

test "GraphBuilder: addEdge with non-existent source returns InvalidNode" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const destination = try builder.addNode();
    const dangling_node = azigmuth.NodeId{ .index = 999 };

    try testing.expectError(error.InvalidNode, builder.addEdge(dangling_node, destination, 0, .{}));
    try testing.expectError(error.InvalidNode, builder.addEdge(destination, dangling_node, 0, .{}));
}

test "GraphBuilder: addEdge with self-loop works correctly" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const node = try builder.addNode();
    try builder.addEdge(node, node, 7, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, node, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, node, testing.allocator));
}

test "graph_builder: duplicate edge returns EdgeAlreadyExists" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const a = try builder.addNode();
    const b = try builder.addNode();

    try builder.addEdge(a, b, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, builder.addEdge(a, b, 1, .{}));

    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, a, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, b, testing.allocator));
}

test "graph_builder: freeze produces valid graph (validate passthrough)" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    var nodes: [6]azigmuth.NodeId = undefined;
    for (0..6) |i| nodes[i] = try builder.addNode();

    try builder.addEdge(nodes[0], nodes[1], 0, .{});
    try builder.addEdge(nodes[0], nodes[2], 0, .{});
    try builder.addEdge(nodes[1], nodes[3], 0, .{});
    try builder.addEdge(nodes[2], nodes[3], 0, .{});
    try builder.addEdge(nodes[3], nodes[4], 0, .{});
    try builder.addEdge(nodes[4], nodes[5], 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try testing.expectEqual(@as(u64, 6), graph.edgeCount());

    try testing.expectEqual(@as(usize, 2), try snapshot_support.outDegree(graph, nodes[0], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, nodes[1], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, nodes[2], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, nodes[3], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, nodes[4], testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, nodes[5], testing.allocator));

    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, nodes[0], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, nodes[1], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, nodes[2], testing.allocator));
    try testing.expectEqual(@as(usize, 2), try snapshot_support.inDegree(graph, nodes[3], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, nodes[4], testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, nodes[5], testing.allocator));
}

test "graph_builder: degree cache is correct after freeze" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    for (0..65) |_| {
        const target = try builder.addNode();
        try builder.addEdge(source, target, 0, .{});
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try testing.expectEqual(@as(usize, 65), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(u64, 65), graph.edgeCount());
}

test "graph_builder: empty graph validates" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "graph_builder: single edge bidirectional check" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const a = try builder.addNode();
    const b = try builder.addNode();
    try builder.addEdge(a, b, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();

    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, a, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, a, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, b, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, b, testing.allocator));
}

test "graph_builder: degree cache matches edge count for large graph" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const n = try builder.addNode();
    for (0..200) |_| {
        const t = try builder.addNode();
        try builder.addEdge(n, t, 0, .{});
    }

    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();

    try testing.expectEqual(@as(usize, 200), try snapshot_support.outDegree(graph, n, testing.allocator));
    try testing.expectEqual(@as(u64, 200), graph.edgeCount());

    for (1..201) |dst_index| {
        try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, .{ .index = @intCast(dst_index) }, testing.allocator));
    }
}

test "graph_builder: freeze transfers ownership and builder becomes inert" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const a = try builder.addNode();
    try builder.addEdge(a, a, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expectError(error.UnsupportedOperation, builder.addNode());
    try testing.expectError(error.UnsupportedOperation, builder.addEdge(a, a, 0, .{}));
    try testing.expectError(error.UnsupportedOperation, builder.freeze());

    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "graph_builder: frozen graph lifetime is independent of builder" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    const node = try builder.addNode();

    var graph = try builder.freeze();
    builder.deinit();

    try testing.expect(graph.hasNode(node));
    graph.deinit();
}

test "graph_builder: frozen graph remains mutable after freeze" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    const extra = try graph.addNode();
    try graph.addEdge(destination, extra, 1, .{});
    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());

    var iter = try snapshot_support.neighbors(graph, destination, testing.allocator);
    defer iter.deinit();
    try testing.expectEqual(extra.index, iter.next().?.index);

    var source_iter = try snapshot_support.neighbors(graph, source, testing.allocator);
    defer source_iter.deinit();
    try testing.expectEqual(destination.index, source_iter.next().?.index);
}

test "graph_builder: 500+ edges freeze produces a valid graph with zero debug violations" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const node_count: u32 = 100;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try builder.addNode();

    var edge_count: usize = 0;
    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i == j) continue;
            if (edge_count >= 520) break;
            try builder.addEdge(nodes[i], nodes[j], 0, .{});
            edge_count += 1;
        }
        if (edge_count >= 520) break;
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    try testing.expect(edge_count >= 500);
    try graph.validate();

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    try testing.expect(graph.edgeCount() > 0);
}
