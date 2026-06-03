const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

test "iterator: materializeExact with capacity larger than snapshotDegree uses snapshot capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [5]graph_mod.NodeId = undefined;
    for (0..5) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, 0);
    }

    var it = try graph.neighbors(source);
    const result = try it.materializeExact(testing.allocator, 100);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 5), result.len);
}

test "iterator: materializeExact with capacity of 0 still returns correct neighbors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    var it = try graph.neighbors(source);
    const result = try it.materializeExact(testing.allocator, 0);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(target.index, result[0].index);
}

test "iterator: snapshotDegree matches materialize length for forward neighbors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..10) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, 0);
    }

    var it = try graph.neighbors(source);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 10), it.snapshotDegree());
    const materialized = try it.materialize(testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 10), materialized.len);
}

test "iterator: snapshotDegree matches materialize length for inNeighbors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var sources: [10]graph_mod.NodeId = undefined;
    for (0..10) |i| {
        sources[i] = try graph.addNode();
        try graph.addEdge(sources[i], hub, 0, 0);
    }

    var it = try graph.inNeighbors(hub);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 10), it.snapshotDegree());
    const materialized = try it.materialize(testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 10), materialized.len);
}

test "iterator: snapshotDegree for inNeighbors with grouped reverse adjacency returns correct count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..131) |_| _ = try graph.addNode();

    const hub = @as(graph_mod.NodeId, .{ .index = 0 });

    const block0 = try graph.allocBlockRev();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, block0, .rev);
    for (0..64) |i| {
        blk0.sources[i] = @intCast(i + 1);
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    const block1 = try graph.allocBlockRev();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, block1, .rev);
    for (0..64) |i| {
        blk1.sources[i] = @intCast(i + 65);
    }
    blk1.mask = constants.FULL_BLOCK_MASK;

    const block2 = try graph.allocBlockRev();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, block2, .rev);
    for (0..2) |i| {
        blk2.sources[i] = @intCast(i + 129);
    }
    blk2.mask = constants.denseMask(2);

    const group0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 1, .next = constants.END_OF_CHAIN };
    const group1 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block1, .count = 1, .next = constants.END_OF_CHAIN };
    page_ops.groupAt(&graph.graph, group0).next = group1;
    const group2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group2).* = .{ .start = block2, .count = 1, .next = constants.END_OF_CHAIN };
    page_ops.groupAt(&graph.graph, group1).next = group2;

    const node = try graph.nodeAt(hub);
    publish.publishedRevSide(node).block_count = 3;
    publish.publishedRevSide(node).group_count = 3;
    publish.publishedRevSide(node).first_group = group0;
    publish.setPublishedRevDegree(node, @as(u22, @intCast(130)));

    var it = try graph.inNeighbors(hub);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 130), it.snapshotDegree());

    const materialized = try it.materialize(testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 130), materialized.len);
}
