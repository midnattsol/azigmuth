const std = @import("std");
const gz = @import("graphz");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

test "multigraph: init with multigraph option creates graph" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    _ = try graph.addNode();
    _ = try graph.addNode();
}

test "multigraph: duplicate addEdge succeeds in multigraph mode" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});
}

test "multigraph: duplicate addEdge fails in simple mode" {
    var graph = try gz.Graph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destination, 0, .{}));
}

test "multigraph: addEdgeWithId returns distinct EdgeIds" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    const id1 = try graph.addEdgeWithId(source, destination, 0, .{});
    const id2 = try graph.addEdgeWithId(source, destination, 1, .{});
    try testing.expect(id1.local != 0);
    try testing.expect(id1.local != id2.local);
}

test "multigraph: EdgeId APIs are unsupported in simple mode" {
    var graph = try gz.Graph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();

    try testing.expectError(error.UnsupportedOperation, graph.addEdgeWithId(source, destination, 0, .{}));
    try testing.expectError(error.UnsupportedOperation, graph.removeEdgeWithId(source, destination, .{ .local = 1 }));
    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    try testing.expectError(error.UnsupportedOperation, snapshot.outEdges(source));
}

test "multigraph: neighbors returns duplicate destinations" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});

    var neighbor_iterator = try snapshot_support.neighbors(graph, source, testing.allocator);
    defer neighbor_iterator.deinit();
    var count: usize = 0;
    while (neighbor_iterator.next()) |neighbor| {
        try testing.expectEqual(destination.index, neighbor.index);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "multigraph: outDegree reflects duplicate edges" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});
    try testing.expectEqual(@as(usize, 2), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(usize, 2), try snapshot_support.inDegree(graph, destination, testing.allocator));
}

test "multigraph: removeEdgeWithId removes specific edge" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    const id1 = try graph.addEdgeWithId(source, destination, 0, .{});
    _ = try graph.addEdgeWithId(source, destination, 1, .{});

    try testing.expect(try graph.removeEdgeWithId(source, destination, id1));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, destination, testing.allocator));

    var neighbor_iterator = try snapshot_support.neighbors(graph, source, testing.allocator);
    defer neighbor_iterator.deinit();
    try testing.expect(neighbor_iterator.next() != null);
    try testing.expect(neighbor_iterator.next() == null);
}

test "multigraph: removeEdge removes all duplicates" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});

    try testing.expect(try graph.removeEdge(source, destination));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, destination, testing.allocator));
}

test "multigraph: validate passes after mutations" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const middle = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, middle, 0, .{});
    try graph.addEdge(source, middle, 1, .{});
    try graph.addEdge(middle, destination, 0, .{});
    try graph.validate();

    const extra = try graph.addEdgeWithId(source, middle, 2, .{});
    _ = try graph.removeEdgeWithId(source, middle, extra);
    try graph.validate();
}

test "multigraph: removeNode cleans up duplicate reverse entries" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});

    _ = try graph.removeNode(source);
    try testing.expect(!graph.hasNode(source));
    try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, destination, testing.allocator));
    try graph.validate();
}

test "multigraph: removeNode decrements predecessor degree by duplicate count" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const predecessor = try graph.addNode();
    const removed_node = try graph.addNode();
    try graph.addEdge(predecessor, removed_node, 0, .{});
    try graph.addEdge(predecessor, removed_node, 1, .{});

    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    _ = try graph.removeNode(removed_node);

    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, predecessor, testing.allocator));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "multigraph: outEdges exposes EdgeRef with IDs" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    const id1 = try graph.addEdgeWithId(source, destination, 10, .{});
    const id2 = try graph.addEdgeWithId(source, destination, 20, .{});

    var out_edge_iterator = try snapshot_support.outEdges(graph, source, testing.allocator);
    defer out_edge_iterator.deinit();
    const first_ref = out_edge_iterator.next().?;
    const second_ref = out_edge_iterator.next().?;
    try testing.expect(out_edge_iterator.next() == null);

    try testing.expectEqual(destination.index, first_ref.destination);
    try testing.expectEqual(destination.index, second_ref.destination);
    const ids = [_]u32{ first_ref.id.local, second_ref.id.local };
    try testing.expect((ids[0] == id1.local and ids[1] == id2.local) or
        (ids[0] == id2.local and ids[1] == id1.local));
}

test "multigraph: outEdges orders duplicate destinations by EdgeId and preserves metadata" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const flags_1 = gz.EdgeFlags{ ._unused = 0x11 };
    const flags_2 = gz.EdgeFlags{ ._unused = 0x22 };
    const id_1 = try graph.addEdgeWithId(source, destination, 7, flags_1);
    const id_2 = try graph.addEdgeWithId(source, destination, 9, flags_2);

    var out_edge_iterator = try snapshot_support.outEdges(graph, source, testing.allocator);
    defer out_edge_iterator.deinit();

    const first_edge = out_edge_iterator.next().?;
    const second_edge = out_edge_iterator.next().?;
    try testing.expect(out_edge_iterator.next() == null);

    try testing.expectEqual(destination.index, first_edge.destination);
    try testing.expectEqual(destination.index, second_edge.destination);
    try testing.expect(first_edge.id.local < second_edge.id.local);
    try testing.expectEqual(id_1.local, first_edge.id.local);
    try testing.expectEqual(id_2.local, second_edge.id.local);
    try testing.expectEqual(@as(u16, 7), first_edge.relation);
    try testing.expectEqual(@as(u16, 9), second_edge.relation);
    try testing.expectEqual(flags_1, first_edge.flags);
    try testing.expectEqual(flags_2, second_edge.flags);
}

test "multigraph: builder accepts duplicates in multigraph mode" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});
    try builder.addEdge(source, destination, 1, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 2), try snapshot_support.outDegree(graph, source, testing.allocator));
    try graph.validate();
}

test "multigraph: builder freeze seeds next EdgeId by source max" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const source = try builder.addNode();
    const destination_one = try builder.addNode();
    const destination_two = try builder.addNode();

    try builder.addEdge(source, destination_two, 0, .{});
    try builder.addEdge(source, destination_one, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const next_id = try graph.addEdgeWithId(source, destination_two, 1, .{});
    try testing.expectEqual(@as(u32, 3), next_id.local);
    try graph.validate();
}

test "multigraph: builder freeze seeds next EdgeId independently per source" {
    var builder = try gz.GraphBuilder.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer builder.deinit();
    const first_source = try builder.addNode();
    const second_source = try builder.addNode();
    const destination_one = try builder.addNode();
    const destination_two = try builder.addNode();
    const destination_three = try builder.addNode();

    try builder.addEdge(first_source, destination_one, 0, .{});
    try builder.addEdge(first_source, destination_two, 0, .{});
    try builder.addEdge(second_source, destination_three, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();

    const next_first_source = try graph.addEdgeWithId(first_source, destination_three, 1, .{});
    const next_second_source = try graph.addEdgeWithId(second_source, destination_one, 1, .{});
    try testing.expectEqual(@as(u32, 3), next_first_source.local);
    try testing.expectEqual(@as(u32, 2), next_second_source.local);
    try graph.validate();
}

test "multigraph: removeEdge preserves grouped reverse entries after duplicates" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();

    var others: [80]gz.NodeId = undefined;
    for (0..others.len) |idx| {
        others[idx] = try graph.addNode();
    }

    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, destination, 1, .{});
    for (others) |other| {
        try graph.addEdge(other, destination, 0, .{});
    }

    try testing.expectEqual(@as(usize, 82), try snapshot_support.inDegree(graph, destination, testing.allocator));
    const expected_after_other: usize = blk: {
        const remove_result = graph.removeEdge(others[0], destination);
        if (remove_result) |removed_other| {
            try testing.expect(removed_other);
            break :blk 81;
        } else |err| {
            try testing.expectEqual(error.RepairRequired, err);
            break :blk 82;
        }
    };
    try testing.expectEqual(expected_after_other, try snapshot_support.inDegree(graph, destination, testing.allocator));

    try testing.expect(try graph.removeEdge(source, destination));
    try testing.expectEqual(expected_after_other - 2, try snapshot_support.inDegree(graph, destination, testing.allocator));
    try graph.validate();
}

test "multigraph: repair preserves edge IDs" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const source = try graph.addNode();
    var targets: [10]gz.NodeId = undefined;
    for (0..10) |target_idx| {
        targets[target_idx] = try graph.addNode();
    }
    for (0..10) |target_idx| {
        try graph.addEdge(source, targets[target_idx], @intCast(target_idx), .{});
    }
    const duplicate_edge_id = try graph.addEdgeWithId(source, targets[0], 99, .{});
    try graph.repairNode(source);
    try graph.validate();
    try testing.expect(try graph.removeEdgeWithId(source, targets[0], duplicate_edge_id));
}

test "multigraph: repair preserves multiblock duplicate EdgeIds" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const tombstone_target = try graph.addNode();

    var ids: [70]gz.EdgeId = undefined;
    for (0..ids.len) |idx| {
        ids[idx] = try graph.addEdgeWithId(source, destination, @intCast(idx), .{});
    }
    try graph.addEdge(source, tombstone_target, 0, .{});

    _ = try graph.removeNode(tombstone_target);
    try graph.repairNode(source);
    try graph.validate();

    // ids[65] lives in the tail block after repair, and the reverse match is
    // also resolved against the tail block, so the single-removal fast path
    // applies directly instead of demanding another repair round.
    try testing.expect(try graph.removeEdgeWithId(source, destination, ids[65]));
    try testing.expectEqual(@as(usize, 69), try snapshot_support.outDegree(graph, source, testing.allocator));
    try testing.expectEqual(@as(usize, 69), try snapshot_support.inDegree(graph, destination, testing.allocator));
    try graph.validate();
}

test "multigraph: repair keeps duplicate outEdges ordered by EdgeId across blocks" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const tombstone_target = try graph.addNode();

    var ids: [70]gz.EdgeId = undefined;
    for (0..ids.len) |idx| {
        ids[idx] = try graph.addEdgeWithId(source, destination, @intCast(idx), .{});
    }
    try graph.addEdge(source, tombstone_target, 0, .{});

    _ = try graph.removeNode(tombstone_target);
    try graph.repairNode(source);

    var out_edge_iterator = try snapshot_support.outEdges(graph, source, testing.allocator);
    defer out_edge_iterator.deinit();

    var expected_idx: usize = 0;
    while (out_edge_iterator.next()) |edge_ref| : (expected_idx += 1) {
        try testing.expectEqual(destination.index, edge_ref.destination);
        try testing.expectEqual(ids[expected_idx].local, edge_ref.id.local);
        try testing.expectEqual(@as(u16, @intCast(expected_idx)), edge_ref.relation);
    }
    try testing.expectEqual(ids.len, expected_idx);
    try graph.validate();
}

test "multigraph: removeNode with self-edge duplicates" {
    var graph = try gz.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();
    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, .{});
    try graph.addEdge(node, node, 1, .{});
    try testing.expectEqual(@as(usize, 2), try snapshot_support.outDegree(graph, node, testing.allocator));
    try testing.expectEqual(@as(usize, 2), try snapshot_support.inDegree(graph, node, testing.allocator));

    _ = try graph.removeNode(node);
    try testing.expect(!graph.hasNode(node));
    try graph.validate();
}
