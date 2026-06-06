//! removeNode and tombstone handling — structural invariants after
//! node removal, tombstone visibility, and repair compaction.

const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

test "tombstone regression: removeNode clears outgoing from all destinations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var destinations: [6]graphz.NodeId = undefined;
    for (0..destinations.len) |i| {
        destinations[i] = try graph.addNode();
        try graph.addEdge(hub, destinations[i], 0, .{});
    }

    _ = try graph.removeNode(hub);

    try testing.expect(!graph.hasNode(hub));
    try testing.expectEqual(@as(usize, 0), graph.outDegree(hub) catch 0);

    for (destinations[0..]) |d| {
        try testing.expectEqual(@as(usize, 0), try graph.inDegree(d));
    }
    try graph.validate();
}

test "tombstone regression: removeNode leaves invisible incoming tombstones" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [6]graphz.NodeId = undefined;
    for (0..sources.len) |i| {
        sources[i] = try graph.addNode();
        try graph.addEdge(sources[i], target, 0, .{});
    }

    _ = try graph.removeNode(target);

    try testing.expect(!graph.hasNode(target));
    try testing.expectEqual(@as(usize, 0), graph.edgeCount());

    // Live sources must have zero visible outgoing to target.
    for (sources[0..]) |s| {
        try testing.expectEqual(@as(usize, 0), try graph.outDegree(s));
    }
    try graph.validate();
}

test "tombstone regression: reverse residual on removed node is allowed before compaction" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [5]graphz.NodeId = undefined;
    for (0..sources.len) |i| {
        sources[i] = try graph.addNode();
        try graph.addEdge(sources[i], target, 0, .{});
    }

    _ = try graph.removeNode(target);

    try testing.expect(!graph.hasNode(target));
    try testing.expectError(error.InvalidNode, graph.inDegree(target));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (sources) |source| {
        try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    }

    // Structural reverse residuals on the removed node are allowed until
    // repair compacts them away. They must not be reported as public logical
    // mismatches or visible count mismatches.
    try graph.validate();
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    for (violations) |violation| {
        try testing.expect(violation != .forward_reverse_mismatch);
        try testing.expect(violation != .forward_reverse_count_mismatch);
        try testing.expect(violation != .edge_count_mismatch);
    }
}

test "tombstone regression: removeNode self-edge works correctly" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const other = try graph.addNode();

    try graph.addEdge(node, node, 0, .{});
    try graph.addEdge(node, other, 0, .{});
    try graph.addEdge(other, node, 0, .{});

    _ = try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(other));
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(other));

    try graph.validate();
}

test "tombstone regression: removeNode with incoming from already-removed nodes" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, .{});
    try graph.addEdge(c, b, 0, .{});

    // Remove A first — this clears A's forward and B's reverse for A.
    _ = try graph.removeNode(a);
    try graph.validate();

    // Then remove B — B has a stale reverse from A (already removed),
    // plus a live reverse from C.
    _ = try graph.removeNode(b);

    try testing.expect(!graph.hasNode(b));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    // C should have zero visible outgoing edges.
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(c));
    try graph.validate();
}

test "tombstone compaction: removeNode + repairBudgeted eliminates structural tombstones" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [4]graphz.NodeId = undefined;
    for (0..sources.len) |i| {
        sources[i] = try graph.addNode();
        try graph.addEdge(sources[i], target, 0, .{});
    }

    _ = try graph.removeNode(target);
    try graph.validate();

    // Run repair to compact tombstones.
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired > 0);

    // After repair, no structural tombstones should remain.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    for (violations) |v| {
        try testing.expect(v != .forward_tombstone_missing_repair_flag);
    }

    try graph.validate();
}

test "tombstone stress: removeNode on hub with many incoming and outgoing" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const peer_count: usize = 15;
    var peers: [peer_count]graphz.NodeId = undefined;
    for (0..peer_count) |i| {
        peers[i] = try graph.addNode();
        try graph.addEdge(hub, peers[i], 0, .{});
        try graph.addEdge(peers[i], hub, 0, .{});
    }

    try graph.validate();
    _ = try graph.removeNode(hub);

    try testing.expect(!graph.hasNode(hub));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (peers[0..]) |p| {
        try testing.expectEqual(@as(usize, 0), try graph.outDegree(p));
        try testing.expectEqual(@as(usize, 0), try graph.inDegree(p));
    }
    try graph.validate();

    _ = try graph.repairBudgeted(5);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
