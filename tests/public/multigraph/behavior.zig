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
    try testing.expect(id1.local != 0);
    try testing.expect(id1.local != id2.local);
}

test "multigraph: EdgeId APIs are unsupported in simple mode" {
    var g = try gz.Graph.init(testing.allocator);
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();

    try testing.expectError(error.UnsupportedOperation, g.addEdgeWithId(a, b, 0, .{}));
    try testing.expectError(error.UnsupportedOperation, g.removeEdgeWithId(a, b, .{ .local = 1 }));
    try testing.expectError(error.UnsupportedOperation, g.outEdges(a));
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

    _ = try g.removeNode(a);
    try testing.expect(!g.hasNode(a));
    try testing.expectEqual(@as(usize, 0), try g.inDegree(b));
    try g.validate();
}

test "multigraph: removeNode decrements predecessor degree by duplicate count" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    const b = try g.addNode();
    try g.addEdge(a, b, 0, .{});
    try g.addEdge(a, b, 1, .{});

    try testing.expectEqual(@as(u64, 2), g.edgeCount());
    _ = try g.removeNode(b);

    try testing.expectEqual(@as(usize, 0), try g.outDegree(a));
    try testing.expectEqual(@as(u64, 0), g.edgeCount());
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

test "multigraph: outEdges orders duplicate destinations by EdgeId and preserves metadata" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();

    const source = try g.addNode();
    const destination = try g.addNode();
    const flags_1 = gz.EdgeFlags{ ._unused = 0x11 };
    const flags_2 = gz.EdgeFlags{ ._unused = 0x22 };
    const id_1 = try g.addEdgeWithId(source, destination, 7, flags_1);
    const id_2 = try g.addEdgeWithId(source, destination, 9, flags_2);

    var it = try g.outEdges(source);
    defer it.deinit();

    const first = it.next().?;
    const second = it.next().?;
    try testing.expect(it.next() == null);

    try testing.expectEqual(destination.index, first.destination);
    try testing.expectEqual(destination.index, second.destination);
    try testing.expect(first.id.local < second.id.local);
    try testing.expectEqual(id_1.local, first.id.local);
    try testing.expectEqual(id_2.local, second.id.local);
    try testing.expectEqual(@as(u16, 7), first.relation);
    try testing.expectEqual(@as(u16, 9), second.relation);
    try testing.expectEqual(flags_1, first.flags);
    try testing.expectEqual(flags_2, second.flags);
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

test "multigraph: builder freeze seeds next EdgeId by source max" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const a = try builder.addNode();
    const b = try builder.addNode();
    const c = try builder.addNode();

    try builder.addEdge(a, c, 0, .{});
    try builder.addEdge(a, b, 0, .{});

    var g = try builder.freeze();
    defer g.deinit();

    const next_id = try g.addEdgeWithId(a, c, 1, .{});
    try testing.expectEqual(@as(u32, 3), next_id.local);
    try g.validate();
}

test "multigraph: builder freeze seeds next EdgeId independently per source" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const a = try builder.addNode();
    const b = try builder.addNode();
    const c = try builder.addNode();
    const d = try builder.addNode();
    const e = try builder.addNode();

    try builder.addEdge(a, c, 0, .{});
    try builder.addEdge(a, d, 0, .{});
    try builder.addEdge(b, e, 0, .{});

    var g = try builder.freeze();
    defer g.deinit();

    const next_a = try g.addEdgeWithId(a, e, 1, .{});
    const next_b = try g.addEdgeWithId(b, c, 1, .{});
    try testing.expectEqual(@as(u32, 3), next_a.local);
    try testing.expectEqual(@as(u32, 2), next_b.local);
    try g.validate();
}

test "multigraph: removeEdge preserves grouped reverse entries after duplicates" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const source = try g.addNode();
    const destination = try g.addNode();

    var others: [80]gz.NodeId = undefined;
    for (0..others.len) |idx| {
        others[idx] = try g.addNode();
    }

    try g.addEdge(source, destination, 0, .{});
    try g.addEdge(source, destination, 1, .{});
    for (others) |other| {
        try g.addEdge(other, destination, 0, .{});
    }

    try testing.expectEqual(@as(usize, 82), try g.inDegree(destination));
    try testing.expectError(error.RepairRequired, g.removeEdge(others[0], destination));
    try testing.expectEqual(@as(usize, 82), try g.inDegree(destination));

    try testing.expect(try g.removeEdge(source, destination));
    try testing.expectEqual(@as(usize, 80), try g.inDegree(destination));
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

test "multigraph: repair preserves multiblock duplicate EdgeIds" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();

    const source = try g.addNode();
    const destination = try g.addNode();
    const tombstone_target = try g.addNode();

    var ids: [70]gz.EdgeId = undefined;
    for (0..ids.len) |idx| {
        ids[idx] = try g.addEdgeWithId(source, destination, @intCast(idx), .{});
    }
    try g.addEdge(source, tombstone_target, 0, .{});

    _ = try g.removeNode(tombstone_target);
    try g.repairNode(source);
    try g.validate();

    try testing.expectError(error.RepairRequired, g.removeEdgeWithId(source, destination, ids[65]));
    try testing.expectEqual(@as(usize, 70), try g.outDegree(source));
    try testing.expectEqual(@as(usize, 70), try g.inDegree(destination));
    try g.validate();
}

test "multigraph: repair keeps duplicate outEdges ordered by EdgeId across blocks" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();

    const source = try g.addNode();
    const destination = try g.addNode();
    const tombstone_target = try g.addNode();

    var ids: [70]gz.EdgeId = undefined;
    for (0..ids.len) |idx| {
        ids[idx] = try g.addEdgeWithId(source, destination, @intCast(idx), .{});
    }
    try g.addEdge(source, tombstone_target, 0, .{});

    _ = try g.removeNode(tombstone_target);
    try g.repairNode(source);

    var it = try g.outEdges(source);
    defer it.deinit();

    var expected_idx: usize = 0;
    while (it.next()) |edge_ref| : (expected_idx += 1) {
        try testing.expectEqual(destination.index, edge_ref.destination);
        try testing.expectEqual(ids[expected_idx].local, edge_ref.id.local);
        try testing.expectEqual(@as(u16, @intCast(expected_idx)), edge_ref.relation);
    }
    try testing.expectEqual(ids.len, expected_idx);
    try g.validate();
}

test "multigraph: removeNode with self-edge duplicates" {
    var g = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer g.deinit();
    const a = try g.addNode();
    try g.addEdge(a, a, 0, .{});
    try g.addEdge(a, a, 1, .{});
    try testing.expectEqual(@as(usize, 2), try g.outDegree(a));
    try testing.expectEqual(@as(usize, 2), try g.inDegree(a));

    _ = try g.removeNode(a);
    try testing.expect(!g.hasNode(a));
    try g.validate();
}
