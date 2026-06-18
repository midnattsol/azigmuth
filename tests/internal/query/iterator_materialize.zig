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
    for (0..5) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    var it = try graph.neighbors(source);
    const result = try graph_mod.materializeExactConsuming(&it, testing.allocator, 100);
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
    const result = try graph_mod.materializeExactConsuming(&it, testing.allocator, 0);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(target.index, result[0].index);
}

test "iterator: snapshotDegree matches materialize length for forward neighbors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..10) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    var it = try graph.neighbors(source);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 10), graph_mod.snapshotDegree(&it));
    const materialized = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 10), materialized.len);
}

test "iterator: snapshotDegree matches materialize length for inNeighbors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var sources: [10]graph_mod.NodeId = undefined;
    for (0..10) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], hub, 0, 0);
    }

    var it = try graph.inNeighbors(hub);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 10), graph_mod.snapshotDegree(&it));
    const materialized = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 10), materialized.len);
}

test "iterator: snapshotDegree for inNeighbors with segmented reverse adjacency returns correct count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..131) |_| _ = try graph.addNode();

    const hub = @as(graph_mod.NodeId, .{ .index = 0 });

    const block0 = try graph.allocBlockRev();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, block0, .rev);
    for (0..64) |slot_idx| {
        blk0.sources[slot_idx] = @intCast(slot_idx + 1);
    }
    page_ops.setBlockAliveCount(&graph.graph, block0, .rev, 64);

    const block1 = try graph.allocBlockRev();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, block1, .rev);
    for (0..64) |slot_idx| {
        blk1.sources[slot_idx] = @intCast(slot_idx + 65);
    }
    page_ops.setBlockAliveCount(&graph.graph, block1, .rev, 64);

    const block2 = try graph.allocBlockRev();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, block2, .rev);
    for (0..2) |slot_idx| {
        blk2.sources[slot_idx] = @intCast(slot_idx + 129);
    }
    page_ops.setBlockAliveCount(&graph.graph, block2, .rev, @intCast(2));

    const segment0 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment0).* = .{ .start = block0, .count = 1 };
    const segment1 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment1).* = .{ .start = block1, .count = 1 };
    const segment2 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment2).* = .{ .start = block2, .count = 1 };

    const node = try graph.nodeAt(hub);
    publish.publishedRevSide(node).block_count = 3;
    publish.publishedRevSide(node).segment_count = 3;
    publish.publishedRevSide(node).first_segment = segment0;
    publish.setPublishedRevDegree(node, @as(u22, @intCast(130)));
    try publish.syncToPublished(&graph, hub.index);

    var it = try graph.inNeighbors(hub);
    defer it.deinit();

    try testing.expectEqual(@as(usize, 130), graph_mod.snapshotDegree(&it));

    const materialized = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(materialized);
    try testing.expectEqual(@as(usize, 130), materialized.len);
}
