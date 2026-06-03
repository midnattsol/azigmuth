const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const testing = std.testing;

test "graph_builder: freeze on empty graph works" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    var g = try b.freeze();
    g.deinit();
}

test "graph_builder: freeze after adding nodes and edges works" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();
    const c = try b.addNode();

    try b.addEdge(a, b_node, 0, 0);
    try b.addEdge(b_node, c, 0, 0);
    try b.addEdge(a, c, 0, 0);

    var g = try b.freeze();
    defer g.deinit();

    try testing.expectEqual(@as(u64, 3), g.edgeCount());
    try testing.expectEqual(@as(usize, 3), g.nodeCount());
    try g.validate();
}

test "graph_builder: duplicate edge returns EdgeAlreadyExists" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();

    try b.addEdge(a, b_node, 0, 0);
    try testing.expectError(error.EdgeAlreadyExists, b.addEdge(a, b_node, 0, 0));
}

test "graph_builder: addEdge to non-existent node returns InvalidNode" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    try testing.expectError(error.InvalidNode, b.addEdge(a, .{ .index = 999 }, 0, 0));
    try testing.expectError(error.InvalidNode, b.addEdge(.{ .index = 999 }, a, 0, 0));
}

test "graph_builder: freeze twice returns UnsupportedOperation" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.freeze());
}

test "graph_builder: addNode after freeze returns UnsupportedOperation" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.addNode());
}

test "graph_builder: addEdge after freeze returns UnsupportedOperation" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.addEdge(a, b_node, 0, 0));
}

test "graph_builder: freeze with no edges returns valid graph" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    _ = try b.addNode();
    _ = try b.addNode();

    var g = try b.freeze();
    defer g.deinit();

    try testing.expectEqual(@as(u64, 0), g.edgeCount());
    try testing.expectEqual(@as(usize, 3), g.nodeCount());
    try g.validate();
}

test "graph_builder: graph from freeze has correct adjacency" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();
    const c = try b.addNode();

    try b.addEdge(a, b_node, 1, 0);
    try b.addEdge(a, c, 2, 0);
    try b.addEdge(b_node, c, 3, 0);

    var g = try b.freeze();
    defer g.deinit();

    var it = try g.neighbors(a);
    const neighbors = try it.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    try testing.expectEqual(b_node.index, neighbors[0].index);
    try testing.expectEqual(c.index, neighbors[1].index);
}

test "graph_builder: self-edge in builder works" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const node = try b.addNode();
    try b.addEdge(node, node, 0, 0);

    var g = try b.freeze();
    defer g.deinit();

    try testing.expectEqual(@as(u64, 1), g.edgeCount());
    try testing.expectEqual(@as(usize, 1), try g.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try g.inDegree(node));
}

test "graph_builder: many edges added then freeze" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const node_count: usize = 10;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try b.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) try b.addEdge(nodes[i], nodes[j], 0, 0);
        }
    }

    var g = try b.freeze();
    defer g.deinit();

    try g.validate();
    try testing.expectEqual(@as(u64, node_count * (node_count - 1)), g.edgeCount());
}

test "graph_builder: builder deinit without freeze frees graph" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    _ = try b.addNode();
}

test "graph_builder: edge ordering sorted after freeze" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const source = try b.addNode();
    var targets: [20]graph_mod.NodeId = undefined;
    for (0..20) |i| targets[i] = try b.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |target_idx| {
        try b.addEdge(source, targets[target_idx], 0, 0);
    }

    var g = try b.freeze();
    defer g.deinit();

    var it = try g.neighbors(source);
    defer it.deinit();
    var prev_idx: u32 = 0;
    var first = true;
    while (it.next()) |neighbor| {
        if (!first) {
            try testing.expect(neighbor.index > prev_idx);
        }
        prev_idx = neighbor.index;
        first = false;
    }
}

test "graph_builder: reverse adjacency sorted after freeze" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const target = try b.addNode();
    var sources: [20]graph_mod.NodeId = undefined;
    for (0..20) |i| sources[i] = try b.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |src_idx| {
        try b.addEdge(sources[src_idx], target, 0, 0);
    }

    var g = try b.freeze();
    defer g.deinit();

    var it = try g.inNeighbors(target);
    defer it.deinit();
    var prev_idx: u32 = 0;
    var first = true;
    while (it.next()) |src_node| {
        if (!first) {
            try testing.expect(src_node.index > prev_idx);
        }
        prev_idx = src_node.index;
        first = false;
    }
}

test "graph_builder: freeze produces graph that passes validate" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const node_count: usize = 15;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try b.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) try b.addEdge(nodes[i], nodes[j], 0, 0);
        }
    }

    var g = try b.freeze();
    defer g.deinit();

    try g.validate();

    const violations = try g.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "graph_builder: degree cache correct after freeze" {
    var b = try graph_mod.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const source = try b.addNode();
    const target_count: usize = 50;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |i| targets[i] = try b.addNode();
    for (0..target_count) |i| try b.addEdge(source, targets[i], 0, 0);

    var g = try b.freeze();
    defer g.deinit();

    try testing.expectEqual(@as(usize, target_count), try g.outDegree(source));
    try g.validate();
}