const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

test "tombstones: neighbors skips removed destination nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_one = try graph.addNode();
    const destination_two = try graph.addNode();
    const destination_three = try graph.addNode();
    try graph.addEdge(source, destination_one, 0, 0);
    try graph.addEdge(source, destination_two, 0, 0);
    try graph.addEdge(source, destination_three, 0, 0);

    _ = try graph.removeNode(destination_two);
    try graph.validate();

    var it = try graph.neighbors(source);
    const neighbors = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    try testing.expectEqual(destination_one.index, neighbors[0].index);
    try testing.expectEqual(destination_three.index, neighbors[1].index);
}

test "tombstones: inNeighbors skips removed source nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const source_one = try graph.addNode();
    const source_two = try graph.addNode();
    const source_three = try graph.addNode();
    try graph.addEdge(source_one, target, 0, 0);
    try graph.addEdge(source_two, target, 0, 0);
    try graph.addEdge(source_three, target, 0, 0);

    _ = try graph.removeNode(source_two);
    try graph.validate();

    var it = try graph.inNeighbors(target);
    const incoming = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(incoming);

    try testing.expectEqual(@as(usize, 2), incoming.len);
    try testing.expectEqual(source_one.index, incoming[0].index);
    try testing.expectEqual(source_three.index, incoming[1].index);
}

test "tombstones: outDegree excludes edges to removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_one = try graph.addNode();
    const destination_two = try graph.addNode();
    const destination_three = try graph.addNode();
    try graph.addEdge(source, destination_one, 0, 0);
    try graph.addEdge(source, destination_two, 0, 0);
    try graph.addEdge(source, destination_three, 0, 0);

    _ = try graph.removeNode(destination_two);
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: inDegree excludes edges from removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const source_one = try graph.addNode();
    const source_two = try graph.addNode();
    const source_three = try graph.addNode();
    try graph.addEdge(source_one, target, 0, 0);
    try graph.addEdge(source_two, target, 0, 0);
    try graph.addEdge(source_three, target, 0, 0);

    _ = try graph.removeNode(source_two);
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(target));
    try graph.validate();
}

test "tombstones: neighbors iterates past multiple consecutive removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..10) |target_idx| targets[target_idx] = try graph.addNode();
    for (0..10) |target_idx| try graph.addEdge(source, targets[target_idx], 0, 0);

    _ = try graph.removeNode(targets[2]);
    _ = try graph.removeNode(targets[5]);
    _ = try graph.removeNode(targets[7]);
    try graph.validate();

    var it = try graph.neighbors(source);
    const neighbors = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 7), neighbors.len);
}

test "tombstones: inNeighbors iterates past multiple consecutive removed sources" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [10]graph_mod.NodeId = undefined;
    for (0..10) |source_idx| sources[source_idx] = try graph.addNode();
    for (0..10) |source_idx| try graph.addEdge(sources[source_idx], target, 0, 0);

    _ = try graph.removeNode(sources[2]);
    _ = try graph.removeNode(sources[5]);
    _ = try graph.removeNode(sources[7]);
    try graph.validate();

    var it = try graph.inNeighbors(target);
    const incoming = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(incoming);

    try testing.expectEqual(@as(usize, 7), incoming.len);
}

test "tombstones: edgeCount excludes all edges to/from removed node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const middle = try graph.addNode();
    const other_source = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, middle, 0, 0);
    try graph.addEdge(source, other_source, 0, 0);
    try graph.addEdge(middle, destination, 0, 0);
    try graph.addEdge(other_source, destination, 0, 0);

    try testing.expectEqual(@as(u64, 4), graph.edgeCount());

    _ = try graph.removeNode(destination);
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());

    try graph.validate();
}

test "tombstones: self-edge removed node excluded from all queries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const destination = try graph.addNode();
    const incoming_source = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);
    try graph.addEdge(node, destination, 0, 0);
    try graph.addEdge(incoming_source, node, 0, 0);

    _ = try graph.removeNode(node);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(destination));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(incoming_source));
    try graph.validate();
}

test "tombstones: outDegree at boundary with many tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [20]graph_mod.NodeId = undefined;
    for (0..20) |target_idx| targets[target_idx] = try graph.addNode();
    for (0..20) |target_idx| try graph.addEdge(source, targets[target_idx], 0, 0);

    for (0..20) |target_idx| {
        if (target_idx % 2 == 0) _ = try graph.removeNode(targets[target_idx]);
    }

    try testing.expectEqual(@as(usize, 10), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: inDegree at boundary with many tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [20]graph_mod.NodeId = undefined;
    for (0..20) |source_idx| sources[source_idx] = try graph.addNode();
    for (0..20) |source_idx| try graph.addEdge(sources[source_idx], target, 0, 0);

    for (0..20) |source_idx| {
        if (source_idx % 2 == 0) _ = try graph.removeNode(sources[source_idx]);
    }

    try testing.expectEqual(@as(usize, 10), try graph.inDegree(target));
    try graph.validate();
}

test "tombstones: node pointing to multiple removed nodes has correct degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var removals: [8]graph_mod.NodeId = undefined;
    var survivors: [4]graph_mod.NodeId = undefined;
    for (0..8) |removal_idx| removals[removal_idx] = try graph.addNode();
    for (0..4) |survivor_idx| survivors[survivor_idx] = try graph.addNode();

    for (0..8) |removal_idx| try graph.addEdge(source, removals[removal_idx], 0, 0);
    for (0..4) |survivor_idx| try graph.addEdge(source, survivors[survivor_idx], 0, 0);

    for (0..8) |removal_idx| _ = try graph.removeNode(removals[removal_idx]);

    try testing.expectEqual(@as(usize, 4), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: validate correctly counts visible edges only" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();
    try graph.addEdge(first, second, 0, 0);
    try graph.addEdge(second, third, 0, 0);
    try graph.addEdge(third, first, 0, 0);

    _ = try graph.removeNode(second);
    try graph.validate();

    var first_neighbors_it = try graph.neighbors(first);
    const first_neighbors = try graph_mod.materializeConsuming(&first_neighbors_it, testing.allocator);
    defer testing.allocator.free(first_neighbors);
    try testing.expectEqual(@as(usize, 0), first_neighbors.len);

    var third_incoming_it = try graph.inNeighbors(third);
    const third_incoming = try graph_mod.materializeConsuming(&third_incoming_it, testing.allocator);
    defer testing.allocator.free(third_incoming);
    try testing.expectEqual(@as(usize, 0), third_incoming.len);
}

test "tombstones: neighbors returns empty when all destinations are removed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_one = try graph.addNode();
    const destination_two = try graph.addNode();
    try graph.addEdge(source, destination_one, 0, 0);
    try graph.addEdge(source, destination_two, 0, 0);

    _ = try graph.removeNode(destination_one);
    _ = try graph.removeNode(destination_two);

    var it = try graph.neighbors(source);
    const neighbors = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 0), neighbors.len);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "tombstones: inNeighbors returns empty when all sources are removed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const source_one = try graph.addNode();
    const source_two = try graph.addNode();
    try graph.addEdge(source_one, target, 0, 0);
    try graph.addEdge(source_two, target, 0, 0);

    _ = try graph.removeNode(source_one);
    _ = try graph.removeNode(source_two);

    var it = try graph.inNeighbors(target);
    const incoming = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(incoming);
    try testing.expectEqual(@as(usize, 0), incoming.len);
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(target));
}

test "tombstones: large hub with many incoming tombstones is correct after repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const sender_count: usize = 50;
    var senders: [sender_count]graph_mod.NodeId = undefined;
    for (0..sender_count) |sender_idx| senders[sender_idx] = try graph.addNode();
    for (0..sender_count) |sender_idx| try graph.addEdge(senders[sender_idx], hub, 0, 0);

    for (0..sender_count) |sender_idx| {
        if (sender_idx % 2 == 0) _ = try graph.removeNode(senders[sender_idx]);
    }

    try testing.expectEqual(@as(usize, 25), try graph.inDegree(hub));
    try graph.validate();

    _ = try graph.repairBudgeted(50);
    try graph.validate();

    const after_adj = try graph.publishedNodeAdj(hub);
    try testing.expect(!after_adj.flags.needs_repair_rev);

    try testing.expectEqual(@as(usize, 25), try graph.inDegree(hub));
    try testing.expectEqual(@as(u64, 25), graph.edgeCount());
}

test "tombstones: repairNode removes tombstones from forward adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var removals: [10]graph_mod.NodeId = undefined;
    for (0..10) |removal_idx| removals[removal_idx] = try graph.addNode();
    for (0..10) |removal_idx| try graph.addEdge(source, removals[removal_idx], 0, 0);

    for (0..10) |removal_idx| _ = try graph.removeNode(removals[removal_idx]);

    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try graph.validate();

    _ = try graph.repairNode(source);
    try graph.validate();

    const after_adj = try graph.publishedNodeAdj(source);
    try testing.expect(!after_adj.flags.needs_repair_fwd);

    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}
