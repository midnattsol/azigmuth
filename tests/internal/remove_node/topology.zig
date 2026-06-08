const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

test "removeNode: hub with many incoming edges cleans up forward and reverse sides" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const source_count: usize = 50;
    var sources: [source_count]graph_mod.NodeId = undefined;
    for (0..source_count) |source_index| {
        sources[source_index] = try graph.addNode();
        try graph.addEdge(sources[source_index], hub, 0, 0);
    }

    const target_count: usize = 8;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(hub, targets[target_index], 0, 0);
    }

    _ = try graph.removeNode(hub);

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (sources) |source| {
        try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    }
    for (targets) |target| {
        try testing.expectEqual(@as(usize, 0), try graph.inDegree(target));
    }

    const new_node = try graph.addNode();
    try testing.expect(graph.hasNode(new_node));

    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "removeNode: new nodes after a removeNode receive fresh monotonic indices" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();

    try graph.addEdge(first, second, 0, 0);
    try graph.addEdge(first, third, 0, 0);

    _ = try graph.removeNode(first);

    const fresh = try graph.addNode();
    try testing.expect(fresh.index > third.index);

    try graph.addEdge(fresh, second, 0, 0);

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(fresh));
    try graph.validate();
}

test "block capacity: 64th edge keeps a single block, 65th triggers a second block" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [64]graph_mod.NodeId = undefined;
    for (0..64) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], 0, 0);
    }

    const after_64 = try graph.publishedNodeAdj(source);
    try testing.expectEqual(@as(u16, 1), after_64.block_count_fwd);
    try testing.expectEqual(@as(u16, 0), after_64.group_count_fwd);
    try testing.expectEqual(@as(usize, 64), try graph.outDegree(source));

    const sixty_fifth = try graph.addNode();
    try graph.addEdge(source, sixty_fifth, 0, 0);

    const after_65 = try graph.publishedNodeAdj(source);
    try testing.expect(after_65.block_count_fwd >= 2);
    try testing.expectEqual(@as(usize, 65), try graph.outDegree(source));

    var iterator = try graph.neighbors(source);
    const neighbor_list = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(neighbor_list);
    try testing.expectEqual(@as(usize, 65), neighbor_list.len);
    var i: usize = 1;
    while (i < neighbor_list.len) : (i += 1) {
        try testing.expect(neighbor_list[i - 1].index < neighbor_list[i].index);
    }
}
