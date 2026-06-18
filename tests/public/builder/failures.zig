const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

test "graph_builder: freeze twice returns UnsupportedOperation" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();
    try testing.expectError(error.UnsupportedOperation, builder.freeze());
}

test "graph_builder: addNode after freeze returns UnsupportedOperation" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();
    try testing.expectError(error.UnsupportedOperation, builder.addNode());
}

test "graph_builder: addEdge after freeze returns UnsupportedOperation" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();
    try testing.expectError(error.UnsupportedOperation, builder.addEdge(source, destination, 0, .{}));
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
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();
    const other = try builder.addNode();

    try builder.addEdge(source, destination, 1, .{});
    try builder.addEdge(source, other, 2, .{});
    try builder.addEdge(destination, other, 3, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    var it = try snapshot_support.neighbors(graph, source, testing.allocator);
    defer it.deinit();
    const neighbors = try it.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    try testing.expectEqual(destination.index, neighbors[0].index);
    try testing.expectEqual(other.index, neighbors[1].index);
}

test "graph_builder: builder deinit without freeze frees graph" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    _ = try builder.addNode();
    _ = try builder.addNode();
}

test "graph_builder: edge ordering sorted after freeze" {
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const source = try builder.addNode();
    var targets: [20]azigmuth.NodeId = undefined;
    for (0..20) |target_idx| targets[target_idx] = try builder.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |target_idx| {
        try builder.addEdge(source, targets[target_idx], 0, .{});
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    var it = try snapshot_support.neighbors(graph, source, testing.allocator);
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
    var builder = try azigmuth.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const target = try builder.addNode();
    var sources: [20]azigmuth.NodeId = undefined;
    for (0..20) |source_idx| sources[source_idx] = try builder.addNode();

    const insertion_order = [_]usize{ 15, 3, 8, 1, 19, 7, 12, 0, 5, 17, 2, 14, 9, 11, 6, 18, 4, 13, 16, 10 };
    for (insertion_order) |source_idx| {
        try builder.addEdge(sources[source_idx], target, 0, .{});
    }

    var graph = try builder.freeze();
    defer graph.deinit();

    var it = try snapshot_support.inNeighbors(graph, target, testing.allocator);
    defer it.deinit();
    var prev_idx: u32 = 0;
    var first = true;
    while (it.next()) |source_node| {
        if (!first) {
            try testing.expect(source_node.index > prev_idx);
        }
        prev_idx = source_node.index;
        first = false;
    }
}
