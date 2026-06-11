//! removeNode and tombstone handling — logical removal semantics,
//! tombstone visibility, and explicit repair compaction.

const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");

const testing = std.testing;

test "tombstone regression: removeNode decrements destination inDegree without immediate reverse cleanup" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var destinations: [6]azigmuth.NodeId = undefined;
    for (0..destinations.len) |destination_idx| {
        destinations[destination_idx] = try graph.addNode();
        try graph.addEdge(hub, destinations[destination_idx], 0, .{});
    }

    _ = try graph.removeNode(hub);

    try testing.expect(!graph.hasNode(hub));
    try testing.expectEqual(@as(usize, 0), snapshot_support.outDegree(graph, hub, testing.allocator) catch 0);

    for (destinations[0..]) |destination| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, destination, testing.allocator));
    }
    try graph.validate();
}

test "tombstone regression: removeNode leaves invisible incoming tombstones" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [6]azigmuth.NodeId = undefined;
    for (0..sources.len) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], target, 0, .{});
    }

    _ = try graph.removeNode(target);

    try testing.expect(!graph.hasNode(target));
    try testing.expectEqual(@as(usize, 0), graph.edgeCount());

    // Live sources must have zero visible outgoing to target.
    for (sources[0..]) |source| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, source, testing.allocator));
    }
    try graph.validate();
}

test "tombstone regression: removed node publishes empty reverse side immediately" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [5]azigmuth.NodeId = undefined;
    for (0..sources.len) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], target, 0, .{});
    }

    _ = try graph.removeNode(target);

    try testing.expect(!graph.hasNode(target));
    try testing.expectError(error.InvalidNode, snapshot_support.inDegree(graph, target, testing.allocator));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (sources) |source| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, source, testing.allocator));
    }

    try graph.validate();
    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tombstone regression: removeNode self-edge works correctly" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const other = try graph.addNode();

    try graph.addEdge(node, node, 0, .{});
    try graph.addEdge(node, other, 0, .{});
    try graph.addEdge(other, node, 0, .{});

    _ = try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, other, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, other, testing.allocator));

    try graph.validate();
}

test "tombstone regression: removeNode with incoming from already-removed nodes" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_source = try graph.addNode();
    const removed_node = try graph.addNode();
    const live_source = try graph.addNode();

    try graph.addEdge(removed_source, removed_node, 0, .{});
    try graph.addEdge(live_source, removed_node, 0, .{});

    // Remove A first — A becomes logically absent, but B may retain
    // structural reverse tombstones until explicit repair.
    _ = try graph.removeNode(removed_source);
    try graph.validate();

    // Then remove B — B has a stale reverse from A (already removed),
    // plus a live reverse from C.
    _ = try graph.removeNode(removed_node);

    try testing.expect(!graph.hasNode(removed_node));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    // C should have zero visible outgoing edges.
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, live_source, testing.allocator));
    try graph.validate();
}

test "tombstone compaction: removeNode + repairBudgeted eliminates structural tombstones" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [4]azigmuth.NodeId = undefined;
    for (0..sources.len) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], target, 0, .{});
    }

    _ = try graph.removeNode(target);
    try graph.validate();

    // Run repair to compact tombstones.
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired > 0);

    // After repair, no structural tombstones should remain.
    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    for (violations) |violation| {
        try testing.expect(violation != .forward_tombstone_missing_repair_flag);
    }

    try graph.validate();
}

test "tombstone stress: removeNode on hub with many incoming and outgoing" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const peer_count: usize = 15;
    var peers: [peer_count]azigmuth.NodeId = undefined;
    for (0..peer_count) |peer_idx| {
        peers[peer_idx] = try graph.addNode();
        try graph.addEdge(hub, peers[peer_idx], 0, .{});
        try graph.addEdge(peers[peer_idx], hub, 0, .{});
    }

    try graph.validate();
    _ = try graph.removeNode(hub);

    try testing.expect(!graph.hasNode(hub));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (peers[0..]) |peer| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, peer, testing.allocator));
        try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, peer, testing.allocator));
    }
    try graph.validate();

    _ = try graph.repairBudgeted(5);

    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
