const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const cycle_mod = test_internals.cycle;

test "empty graph has no cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [0]graph_mod.NodeId = undefined;
    for (0..0) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "single node without edges has no cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [1]graph_mod.NodeId = undefined;
    for (0..1) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "single node with self-loop has cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [1]graph_mod.NodeId = undefined;
    for (0..1) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[0], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "two nodes no cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [2]graph_mod.NodeId = undefined;
    for (0..2) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "two nodes with cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [2]graph_mod.NodeId = undefined;
    for (0..2) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[1], nodes[0], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "three nodes triangle" {
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
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "disconnected graph, one component has cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..4) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[2], nodes[3], 0, 0);
    try builder.addEdge(nodes[3], nodes[2], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "disconnected graph, no cycles" {
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
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "dag with diamond shape has no cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..4) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[0], nodes[2], 0, 0);
    try builder.addEdge(nodes[1], nodes[3], 0, 0);
    try builder.addEdge(nodes[2], nodes[3], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle reached after an acyclic prefix is detected" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..5) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[1], nodes[2], 0, 0);
    try builder.addEdge(nodes[2], nodes[3], 0, 0);
    try builder.addEdge(nodes[3], nodes[1], 0, 0);
    try builder.addEdge(nodes[3], nodes[4], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle detection handles duplicate paths to completed nodes" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..5) |node_index| {
        nodes[node_index] = try builder.addNode();
    }
    try builder.addEdge(nodes[0], nodes[1], 0, 0);
    try builder.addEdge(nodes[0], nodes[2], 0, 0);
    try builder.addEdge(nodes[1], nodes[3], 0, 0);
    try builder.addEdge(nodes[2], nodes[3], 0, 0);
    try builder.addEdge(nodes[3], nodes[4], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle detection ignores removed nodes" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(b, a, 0, 0);
    try graph.removeNode(a);

    try graph.validate();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle detection handles nodes with more than 64 outgoing edges" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const node_count: u32 = 71;
    var nodes: [node_count]graph_mod.NodeId = undefined;

    for (0..node_count) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    // Add 70 edges from node 0 to nodes 1..70, forcing multiple blocks.
    for (1..node_count) |target_index| {
        try builder.addEdge(nodes[0], nodes[target_index], 0, 0);
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try std.testing.expectEqual(@as(u64, 70), graph.edgeCount());
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle detection handles nodes with more than 64 outgoing edges and a self-cycle" {
    var builder = try graph_mod.GraphBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const node_count: u32 = 71;
    var nodes: [node_count]graph_mod.NodeId = undefined;

    for (0..node_count) |node_index| {
        nodes[node_index] = try builder.addNode();
    }

    for (1..node_count) |target_index| {
        try builder.addEdge(nodes[0], nodes[target_index], 0, 0);
    }
    // Self-loop on node 0 creates a cycle with multi-block adjacency.
    try builder.addEdge(nodes[0], nodes[0], 0, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    try graph.validate();
    try std.testing.expectEqual(@as(u64, 71), graph.edgeCount());
    try std.testing.expectEqual(true, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}

test "cycle detection with dense hub and many tombstoned sources is correct" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const sender_count: usize = 100;
    var senders: [sender_count]graph_mod.NodeId = undefined;
    for (0..sender_count) |i| {
        senders[i] = try graph.addNode();
        try graph.addEdge(senders[i], hub, 0, 0);
    }

    for (0..sender_count) |i| {
        if (i % 3 == 0) try graph.removeNode(senders[i]);
    }

    try graph.validate();
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));

    const visible = try graph.inDegree(hub);
    try std.testing.expect(visible > 0);
    try std.testing.expect(visible < sender_count);
}

test "cycle detection with tombstoned self-loop node returns false" {
    var graph = try graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, a, 0, 0);
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(b, c, 0, 0);
    try graph.addEdge(c, a, 0, 0);

    try graph.removeNode(a);
    try graph.validate();

    // The cycle is broken because a is removed.
    try std.testing.expectEqual(false, try cycle_mod.hasCycle(&graph.graph, std.testing.allocator));
}
