const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

test "graph_builder: freeze twice returns UnsupportedOperation" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.freeze());
}

test "graph_builder: addNode after freeze returns UnsupportedOperation" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.addNode());
}

test "graph_builder: addEdge after freeze returns UnsupportedOperation" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();
    var g = try b.freeze();
    defer g.deinit();
    try testing.expectError(error.UnsupportedOperation, b.addEdge(a, b_node, 0, .{}));
}

test "graph_builder: freeze OutOfMemory leaves builder usable" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try azigmuth.GraphBuilder.init(failing_allocator.allocator());
    defer builder.deinit();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, builder.freeze());

    failing_allocator.fail_index = std.math.maxInt(usize);
    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
}

test "graph_builder: freeze internal OutOfMemory leaves builder usable" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try azigmuth.GraphBuilder.init(failing_allocator.allocator());
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    failing_allocator.fail_index = failing_allocator.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, builder.freeze());

    failing_allocator.fail_index = std.math.maxInt(usize);
    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "graph_builder: graph from freeze has correct adjacency" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addNode();
    const b_node = try b.addNode();
    const c = try b.addNode();

    try b.addEdge(a, b_node, 1, .{});
    try b.addEdge(a, c, 2, .{});
    try b.addEdge(b_node, c, 3, .{});

    var g = try b.freeze();
    defer g.deinit();

    var it = try snapshot_support.neighbors(g, a, testing.allocator);
    defer it.deinit();
    const neighbors = try it.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    try testing.expectEqual(b_node.index, neighbors[0].index);
    try testing.expectEqual(c.index, neighbors[1].index);
}

test "graph_builder: builder deinit without freeze frees graph" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    _ = try b.addNode();
    _ = try b.addNode();
}

test "graph_builder: edge ordering sorted after freeze" {
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const source = try b.addNode();
    var targets: [20]azigmuth.NodeId = undefined;
    for (0..20) |i| targets[i] = try b.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |target_idx| {
        try b.addEdge(source, targets[target_idx], 0, .{});
    }

    var g = try b.freeze();
    defer g.deinit();

    var it = try snapshot_support.neighbors(g, source, testing.allocator);
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
    var b = try azigmuth.GraphBuilder.init(testing.allocator);
    defer b.deinit();

    const target = try b.addNode();
    var sources: [20]azigmuth.NodeId = undefined;
    for (0..20) |i| sources[i] = try b.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |src_idx| {
        try b.addEdge(sources[src_idx], target, 0, .{});
    }

    var g = try b.freeze();
    defer g.deinit();

    var it = try snapshot_support.inNeighbors(g, target, testing.allocator);
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
