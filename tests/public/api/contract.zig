const std = @import("std");
const graphz = @import("graphz");
const snapshot_api = @import("snapshot_api.zig");

const testing = std.testing;

// ── Lifecycle ──────────────────────────────────────────────────────────────

test "contract: deinitChecked fails with active snapshot and handle stays usable" {
    var graph = try graphz.Graph.init(testing.allocator);
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var snapshot = try graph.snapshot(testing.allocator);

    try testing.expectError(error.GraphBusy, graph.deinitChecked());
    snapshot.deinit();
    graph.deinit();
}

test "contract: deinitChecked succeeds on clean graph and consumes handle" {
    var graph = try graphz.Graph.init(testing.allocator);
    try graph.deinitChecked();
}

// ── Iterator ───────────────────────────────────────────────────────────────

test "contract: materialize with defer deinit is safe" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..3) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 3), neighbors.len);
}

test "contract: materialize then deinit does not double-free" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    iter.deinit();
}

test "contract: next after materialize returns null" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 1), neighbors.len);
    try testing.expect(iter.next() == null);
    iter.deinit();
}

test "contract: neighbors returns by value (no alloc on creation)" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();
    const neighbor = iter.next().?;
    try testing.expectEqual(destination.index, neighbor.index);
}

test "contract: empty iterator materialize returns empty slice" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var iter = try snapshot_api.neighbors(graph, node, testing.allocator);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 0), neighbors.len);
    iter.deinit();
}

test "contract: double deinit on iterator is harmless" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    iter.deinit();
    iter.deinit();
}

test "contract: iterator remains usable until owner deinit" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const first_destination = try graph.addNode();
    const second_destination = try graph.addNode();
    try graph.addEdge(source, first_destination, 0, .{});
    try graph.addEdge(source, second_destination, 0, .{});

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();

    try testing.expect(iter.next() != null);
    const remaining = try iter.materialize(testing.allocator);
    defer testing.allocator.free(remaining);
    try testing.expectEqual(@as(usize, 1), remaining.len);
}

// ── Edge mutations ─────────────────────────────────────────────────────────

test "contract: addEdge with non-zero relation and flags" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 42, .{});
    try graph.validate();

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();
    try testing.expectEqual(destination.index, iter.next().?.index);
}

test "contract: addEdge self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 1, .{});
    try graph.validate();

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try snapshot_api.outDegree(graph, node, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_api.inDegree(graph, node, testing.allocator));

    var iter = try snapshot_api.neighbors(graph, node, testing.allocator);
    defer iter.deinit();
    try testing.expectEqual(node.index, iter.next().?.index);
}

test "contract: addEdge duplicate returns EdgeAlreadyExists" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destination, 0, .{}));
}

test "contract: removeEdge returns true when edge exists" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(true, try graph.removeEdge(source, destination));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, source, testing.allocator));
    try graph.validate();
}

test "contract: removeEdge returns false when edge does not exist" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(false, try graph.removeEdge(destination, source));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try graph.validate();
}

test "contract: removeEdge self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, .{});

    try testing.expectEqual(true, try graph.removeEdge(node, node));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_api.outDegree(graph, node, testing.allocator));
    try graph.validate();
}

// ── Node mutations ─────────────────────────────────────────────────────────

test "contract: addNode returns unique IDs" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();
    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expect(first.index != second.index);
    try testing.expect(second.index != third.index);
    try testing.expect(third.index != first.index);
}

test "contract: hasNode returns false for out-of-range index" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(false, graph.hasNode(.{ .index = 0 }));
    try testing.expectEqual(false, graph.hasNode(.{ .index = 9999 }));
}

test "contract: nodeCount and edgeCount after mutations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();
    try graph.addEdge(first, second, 0, .{});
    try graph.addEdge(second, third, 1, .{});

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

// ── removeNode ─────────────────────────────────────────────────────────────

test "contract: removeNode invalidates hasNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try testing.expect(graph.hasNode(node));
    _ = try graph.removeNode(node);
    try testing.expect(!graph.hasNode(node));
    try graph.validate();
}

test "contract: removeNode returns summary for repair policy decisions" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});
    try graph.addEdge(target, destination, 0, .{});

    const summary = try graph.removeNode(target);
    try testing.expectEqual(@as(u64, 2), summary.removed_visible_edges);
    try testing.expectEqual(@as(u32, 2), summary.related_live_nodes_touched);
    try testing.expect(summary.left_repair_debt);
}

test "contract: removeNode clears outgoing edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const extra = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, extra, 1, .{});

    _ = try graph.removeNode(source);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var iter = try snapshot_api.neighbors(graph, destination, testing.allocator);
    defer iter.deinit();
    try testing.expect(iter.next() == null);
}

test "contract: removeNode with incoming edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor_one = try graph.addNode();
    const predecessor_two = try graph.addNode();
    try graph.addEdge(predecessor_one, target, 0, .{});
    try graph.addEdge(predecessor_two, target, 1, .{});

    _ = try graph.removeNode(target);
    try graph.validate();

    var iter_one = try snapshot_api.neighbors(graph, predecessor_one, testing.allocator);
    defer iter_one.deinit();
    try testing.expect(iter_one.next() == null);

    var iter_two = try snapshot_api.neighbors(graph, predecessor_two, testing.allocator);
    defer iter_two.deinit();
    try testing.expect(iter_two.next() == null);
}

test "contract: outDegree and inDegree are consistent with neighbors materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    const out_deg = try snapshot_api.outDegree(graph, source, testing.allocator);
    const in_deg = try snapshot_api.inDegree(graph, source, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out_deg);
    try testing.expectEqual(@as(usize, 0), in_deg);

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    const expected_deg = try snapshot_api.outDegree(graph, source, testing.allocator);
    try testing.expectEqual(expected_deg, neighbors.len);
}

test "contract: neighborsMaterialized convenience matches neighbors + materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const first_dst = try graph.addNode();
    const second_dst = try graph.addNode();
    try graph.addEdge(source, first_dst, 0, .{});
    try graph.addEdge(source, second_dst, 0, .{});

    const direct = try snapshot_api.neighborsMaterialized(graph, source, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try snapshot_api.neighbors(graph, source, testing.allocator);
    defer iter.deinit();
    const via_iter = try iter.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
    for (direct, 0..) |neighbor, idx| {
        try testing.expectEqual(neighbor.index, via_iter[idx].index);
    }
}

test "contract: inNeighborsMaterialized convenience matches inNeighbors + materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor_one = try graph.addNode();
    const predecessor_two = try graph.addNode();
    try graph.addEdge(predecessor_one, target, 0, .{});
    try graph.addEdge(predecessor_two, target, 1, .{});

    const direct = try snapshot_api.inNeighborsMaterialized(graph, target, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try snapshot_api.inNeighbors(graph, target, testing.allocator);
    defer iter.deinit();
    const via_iter = try iter.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
}
