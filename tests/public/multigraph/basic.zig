const std = @import("std");
const gz = @import("graphz");
const testing = std.testing;

test "multigraph: init with multigraph option creates graph" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    _ = try g.addNode();
    _ = try g.addNode();
}

test "multigraph: duplicate addEdge succeeds in multigraph mode" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});
}

test "multigraph: duplicate addEdge fails in simple mode" {
    var g = try gz.Graph.init(testing.allocator);
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, g.addEdge(a, b, 0, .{}));
}

test "multigraph: addEdgeWithId returns distinct EdgeIds" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    const id1 = try g.addEdgeWithId(a, b, 0, .{});
    const id2 = try g.addEdgeWithId(a, b, 1, .{});
    try testing.expect(id1.local != id2.local);
}

test "multigraph: neighbors returns duplicate destinations" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});

    var it = try g.neighbors(a);
    defer it.deinit();
    var count: usize = 0;
    while (it.next()) |n| {
        try testing.expectEqual(b.index, n.index);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "multigraph: outDegree reflects duplicate edges" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});
    try testing.expectEqual(@as(usize, 2), try g.outDegree(a));
    try testing.expectEqual(@as(usize, 2), try g.inDegree(b));
}

test "multigraph: removeEdgeWithId removes specific edge" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    const id1 = try g.addEdgeWithId(a, b, 0, .{});
    _ = try g.addEdgeWithId(a, b, 1, .{});

    try testing.expect(try g.removeEdgeWithId(a, b, id1));
    try testing.expectEqual(@as(usize, 1), try g.outDegree(a));
    try testing.expectEqual(@as(usize, 1), try g.inDegree(b));

    var it = try g.neighbors(a);
    defer it.deinit();
    try testing.expect(it.next() != null);
    try testing.expect(it.next() == null);
}

test "multigraph: removeEdge removes all duplicates" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});

    try testing.expect(try g.removeEdge(a, b));
    try testing.expectEqual(@as(usize, 0), try g.outDegree(a));
    try testing.expectEqual(@as(usize, 0), try g.inDegree(b));
}

test "multigraph: validate passes after mutations" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    const c = try g.addNode();

    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});
    try g.addEdge(b, c, 0, .{});
    try g.validate();

    const extra = try g.addEdgeWithId(a, b, 2, .{});
    _ = try g.removeEdgeWithId(a, b, extra);
    try g.validate();
}

test "multigraph: removeNode cleans up duplicate reverse entries" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});

    try g.removeNode(a);
    try testing.expect(!g.hasNode(a));
    try testing.expectEqual(@as(usize, 0), try g.inDegree(b));
    try g.validate();
}

test "multigraph: outEdges exposes EdgeRef with IDs" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    const id1 = try g.addEdgeWithId(a, b, 10, .{});
    const id2 = try g.addEdgeWithId(a, b, 20, .{});

    var it = try g.outEdges(a);
    defer it.deinit();
    const ref1 = it.next().?;
    const ref2 = it.next().?;
    try testing.expect(it.next() == null);

    try testing.expectEqual(b.index, ref1.destination);
    try testing.expectEqual(b.index, ref2.destination);
    const ids = [_]u32{ ref1.id.local, ref2.id.local };
    try testing.expect((ids[0] == id1.local and ids[1] == id2.local) or
        (ids[0] == id2.local and ids[1] == id1.local));
}

test "multigraph: builder accepts duplicates in multigraph mode" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const a = try builder.addNode();
    const b = try builder.addNode();
    try builder.addEdge(a, b, 0, .{});
    try builder.addEdge(a, b, 1, .{});

    var g = try builder.freeze();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), try g.outDegree(a));
    try g.validate();
}

test "multigraph: repair preserves edge IDs" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    var targets: [10]gz.NodeId = undefined;
    for (0..10) |i| {
        targets[i] = try g.addNode();
    }
    for (0..10) |i| {
        try g.addEdge(a, targets[i], @intCast(i), .{});
    }
    const id1 = try g.addEdgeWithId(a, targets[0], 99, .{});
    try g.repairNode(a);
    try g.validate();
    try testing.expect(try g.removeEdgeWithId(a, targets[0], id1));
}

test "multigraph: removeNode with self-edge duplicates" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    try g.addEdge(a, a, 0, .{});
    try g.addEdge(a, a, 1, .{});
    try testing.expectEqual(@as(usize, 2), try g.outDegree(a));
    try testing.expectEqual(@as(usize, 2), try g.inDegree(a));

    try g.removeNode(a);
    try testing.expect(!g.hasNode(a));
    try g.validate();
}
