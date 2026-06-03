const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

test "contract: deinitChecked fails with active iterator and handle stays usable" {
    var g = try graphz.Graph.init(testing.allocator);
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    var it = try g.neighbors(a);
    defer it.deinit();

    try testing.expectError(error.GraphBusy, g.deinitChecked());
    // handle still alive — drop iterator then deinit
    it.deinit();
    g.deinit();
}

test "contract: deinitChecked succeeds on clean graph and consumes handle" {
    var g = try graphz.Graph.init(testing.allocator);
    try g.deinitChecked();
}

test "contract: materialize with defer deinit is safe" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    var targets: [3]graphz.NodeId = undefined;
    for (0..3) |i| {
        targets[i] = try g.addNode();
        try g.addEdge(a, targets[i], 0, .{});
    }

    var it = try g.neighbors(a);
    defer it.deinit();
    const all = try it.materialize(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
}

test "contract: materialize then deinit does not double-free" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    var it = try g.neighbors(a);
    const all = try it.materialize(testing.allocator);
    defer testing.allocator.free(all);
    // deinit after materialize must be safe (idempotent)
    it.deinit();
}

test "contract: next after materialize returns null" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    var it = try g.neighbors(a);
    const all = try it.materialize(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expect(it.next() == null);
    it.deinit();
}

test "contract: neighbors returns by value (no alloc on creation)" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    var it = try g.neighbors(a);
    defer it.deinit();
    const neighbor = it.next().?;
    try testing.expectEqual(b.index, neighbor.index);
}

test "contract: empty iterator materialize returns empty slice" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();

    var it = try g.neighbors(a);
    const all = try it.materialize(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);
    it.deinit();
}

test "contract: builder freeze returns valid mutable Graph handle" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const a = try builder.addNode();
    const b = try builder.addNode();
    try builder.addEdge(a, b, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    var it = try graph.neighbors(a);
    defer it.deinit();
    try testing.expectEqual(b.index, it.next().?.index);
}

test "contract: outDegree and inDegree are consistent with neighbors materialize" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    const out_deg = try g.outDegree(a);
    const in_deg = try g.inDegree(a);
    try testing.expectEqual(@as(usize, 1), out_deg);
    try testing.expectEqual(@as(usize, 0), in_deg);

    var it = try g.neighbors(a);
    defer it.deinit();
    const all = try it.materialize(testing.allocator);
    defer testing.allocator.free(all);

    const expected_deg = try g.outDegree(a);
    try testing.expectEqual(expected_deg, all.len);
}

test "contract: double deinit on iterator is harmless" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    var it = try g.neighbors(a);
    it.deinit();
    it.deinit();
}

test "contract: bfs returns reachable nodes in BFS order" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    const c = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, c, 0, .{});

    const order = try g.bfs(a, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(a.index, order[0].index);
}

test "contract: dfs returns reachable nodes" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    const order = try g.dfs(a, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(a.index, order[0].index);
}

test "contract: hasCycle on DAG returns false" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});

    try testing.expectEqual(false, try g.hasCycle(testing.allocator));
}

test "contract: hasCycle on cycle returns true" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(b, a, 0, .{});

    try testing.expectEqual(true, try g.hasCycle(testing.allocator));
}

test "contract: neighborsMaterialized convenience matches neighbors + materialize" {
    var g = try graphz.Graph.init(testing.allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();
    const c = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, c, 0, .{});

    const direct = try g.neighborsMaterialized(a, testing.allocator);
    defer testing.allocator.free(direct);

    var it = try g.neighbors(a);
    defer it.deinit();
    const via_iter = try it.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
    for (direct, 0..) |neighbor, idx| {
        try testing.expectEqual(neighbor.index, via_iter[idx].index);
    }
}
