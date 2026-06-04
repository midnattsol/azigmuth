const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

// ── Lifecycle ──────────────────────────────────────────────────────────────

test "contract: deinitChecked fails with active iterator and handle stays usable" {
    var graph = try graphz.Graph.init(testing.allocator);
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    defer iter.deinit();

    try testing.expectError(error.GraphBusy, graph.deinitChecked());
    iter.deinit();
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

    var iter = try graph.neighbors(source);
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

    var iter = try graph.neighbors(source);
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

    var iter = try graph.neighbors(source);
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

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const neighbor = iter.next().?;
    try testing.expectEqual(destination.index, neighbor.index);
}

test "contract: empty iterator materialize returns empty slice" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var iter = try graph.neighbors(node);
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

    var iter = try graph.neighbors(source);
    iter.deinit();
    iter.deinit();
}

// ── Edge mutations ─────────────────────────────────────────────────────────

test "contract: addEdge with non-zero relation and flags" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 42, .{});
    try graph.validate();

    var iter = try graph.neighbors(source);
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
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(node));

    var iter = try graph.neighbors(node);
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
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
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
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(node));
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
    try graph.removeNode(node);
    try testing.expect(!graph.hasNode(node));
    try graph.validate();
}

test "contract: removeNode clears outgoing edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const extra = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, extra, 1, .{});

    try graph.removeNode(source);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var iter = try graph.neighbors(destination);
    defer iter.deinit();
    try testing.expect(iter.next() == null);
}

test "contract: neighbors on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.neighbors(node));
}

test "contract: inNeighbors on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, node, 0, .{});
    try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.inNeighbors(node));
}

test "contract: outDegree on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.outDegree(node));
}

test "contract: inDegree on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}

test "contract: removeNode with incoming edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor_one = try graph.addNode();
    const predecessor_two = try graph.addNode();
    try graph.addEdge(predecessor_one, target, 0, .{});
    try graph.addEdge(predecessor_two, target, 1, .{});

    try graph.removeNode(target);
    try graph.validate();

    var iter_one = try graph.neighbors(predecessor_one);
    defer iter_one.deinit();
    try testing.expect(iter_one.next() == null);

    var iter_two = try graph.neighbors(predecessor_two);
    defer iter_two.deinit();
    try testing.expect(iter_two.next() == null);
}

test "contract: removeNode self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const neighbor = try graph.addNode();
    try graph.addEdge(node, node, 0, .{});
    try graph.addEdge(node, neighbor, 1, .{});

    try graph.removeNode(node);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var iter = try graph.neighbors(neighbor);
    defer iter.deinit();
    try testing.expect(iter.next() == null);
}

// ── Repair ─────────────────────────────────────────────────────────────────

test "contract: repairNode on single-block node succeeds" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    try graph.repairNode(source);
    try graph.validate();
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "contract: repairBudgeted returns repaired count" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired <= 1);
    try graph.validate();
}

test "contract: repairBudgeted with max_nodes=0 returns 0" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(@as(usize, 0), try graph.repairBudgeted(0));
}

// ── Validation ─────────────────────────────────────────────────────────────

test "contract: validate passes on empty graph" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();
    try graph.validate();
}

test "contract: validate passes after addEdge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.validate();
}

test "contract: validate passes after removeEdge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    _ = try graph.removeEdge(source, destination);
    try graph.validate();
}

test "contract: debugValidate on empty graph returns no violations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "contract: debugValidate on clean graph returns no violations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// ── Algorithms ─────────────────────────────────────────────────────────────

test "contract: bfs returns reachable nodes in BFS order" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    const middle = try graph.addNode();
    const leaf = try graph.addNode();
    try graph.addEdge(start, middle, 0, .{});
    try graph.addEdge(start, leaf, 0, .{});

    const order = try graph.bfs(start, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(start.index, order[0].index);
}

test "contract: dfs returns reachable nodes" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    const reachable = try graph.addNode();
    try graph.addEdge(start, reachable, 0, .{});

    const order = try graph.dfs(start, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(start.index, order[0].index);
}

test "contract: hasCycle on DAG returns false" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(false, try graph.hasCycle(testing.allocator));
}

test "contract: hasCycle on cycle returns true" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    try graph.addEdge(first, second, 0, .{});
    try graph.addEdge(second, first, 0, .{});

    try testing.expectEqual(true, try graph.hasCycle(testing.allocator));
}

test "contract: outDegree and inDegree are consistent with neighbors materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    const out_deg = try graph.outDegree(source);
    const in_deg = try graph.inDegree(source);
    try testing.expectEqual(@as(usize, 1), out_deg);
    try testing.expectEqual(@as(usize, 0), in_deg);

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    const expected_deg = try graph.outDegree(source);
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

    const direct = try graph.neighborsMaterialized(source, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try graph.neighbors(source);
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

    const direct = try graph.inNeighborsMaterialized(target, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try graph.inNeighbors(target);
    defer iter.deinit();
    const via_iter = try iter.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
}

// ── GraphBuilder ───────────────────────────────────────────────────────────

test "contract: builder freeze returns valid mutable Graph handle" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    try testing.expectEqual(destination.index, iter.next().?.index);
}

test "contract: builder freeze on empty builder succeeds" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "contract: builder freeze with nodes but no edges succeeds" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    _ = try builder.addNode();
    _ = try builder.addNode();
    _ = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "contract: builder become inert after freeze" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();
    defer builder.deinit();

    try testing.expectError(error.UnsupportedOperation, builder.addNode());
    try testing.expectError(error.UnsupportedOperation, builder.freeze());
}

test "contract: builder lifetime is independent of frozen graph" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const node = try builder.addNode();

    var graph = try builder.freeze();
    builder.deinit();

    try testing.expect(graph.hasNode(node));
    graph.deinit();
}

test "contract: frozen graph from builder supports mutations" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
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

    var iter = try graph.neighbors(destination);
    defer iter.deinit();
    try testing.expectEqual(extra.index, iter.next().?.index);

    var reverse_iter = try graph.neighbors(source);
    defer reverse_iter.deinit();
    try testing.expectEqual(destination.index, reverse_iter.next().?.index);
}
