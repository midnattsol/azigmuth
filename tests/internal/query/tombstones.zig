const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

test "tombstones: neighbors skips removed destination nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(source, a, 0, 0);
    try graph.addEdge(source, b, 0, 0);
    try graph.addEdge(source, c, 0, 0);

    _ = try graph.removeNode(b);
    try graph.validate();

    var it = try graph.neighbors(source);
    const neighbors = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(neighbors);

    try testing.expectEqual(@as(usize, 2), neighbors.len);
    try testing.expectEqual(a.index, neighbors[0].index);
    try testing.expectEqual(c.index, neighbors[1].index);
}

test "tombstones: inNeighbors skips removed source nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, target, 0, 0);
    try graph.addEdge(b, target, 0, 0);
    try graph.addEdge(c, target, 0, 0);

    _ = try graph.removeNode(b);
    try graph.validate();

    var it = try graph.inNeighbors(target);
    const incoming = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(incoming);

    try testing.expectEqual(@as(usize, 2), incoming.len);
    try testing.expectEqual(a.index, incoming[0].index);
    try testing.expectEqual(c.index, incoming[1].index);
}

test "tombstones: outDegree excludes edges to removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(source, a, 0, 0);
    try graph.addEdge(source, b, 0, 0);
    try graph.addEdge(source, c, 0, 0);

    _ = try graph.removeNode(b);
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: inDegree excludes edges from removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, target, 0, 0);
    try graph.addEdge(b, target, 0, 0);
    try graph.addEdge(c, target, 0, 0);

    _ = try graph.removeNode(b);
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(target));
    try graph.validate();
}

test "tombstones: neighbors iterates past multiple consecutive removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..10) |i| targets[i] = try graph.addNode();
    for (0..10) |i| try graph.addEdge(source, targets[i], 0, 0);

    _ = try graph.removeNode(targets[2]);
    try graph.removeNode(targets[5]);
    try graph.removeNode(targets[7]);
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
    for (0..10) |i| sources[i] = try graph.addNode();
    for (0..10) |i| try graph.addEdge(sources[i], target, 0, 0);

    _ = try graph.removeNode(sources[2]);
    try graph.removeNode(sources[5]);
    try graph.removeNode(sources[7]);
    try graph.validate();

    var it = try graph.inNeighbors(target);
    const incoming = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(incoming);

    try testing.expectEqual(@as(usize, 7), incoming.len);
}

test "tombstones: edgeCount excludes all edges to/from removed node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    const d = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.addEdge(b, d, 0, 0);
    try graph.addEdge(c, d, 0, 0);

    try testing.expectEqual(@as(u64, 4), graph.edgeCount());

    _ = try graph.removeNode(d);
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());

    try graph.validate();
}

test "tombstones: self-edge removed node excluded from all queries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, a, 0, 0);
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, a, 0, 0);

    _ = try graph.removeNode(a);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(b));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(c));
    try graph.validate();
}

test "tombstones: outDegree at boundary with many tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [20]graph_mod.NodeId = undefined;
    for (0..20) |i| targets[i] = try graph.addNode();
    for (0..20) |i| try graph.addEdge(source, targets[i], 0, 0);

    for (0..20) |i| if (i % 2 == 0) _ = try graph.removeNode(targets[i]);

    try testing.expectEqual(@as(usize, 10), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: inDegree at boundary with many tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    var sources: [20]graph_mod.NodeId = undefined;
    for (0..20) |i| sources[i] = try graph.addNode();
    for (0..20) |i| try graph.addEdge(sources[i], target, 0, 0);

    for (0..20) |i| if (i % 2 == 0) _ = try graph.removeNode(sources[i]);

    try testing.expectEqual(@as(usize, 10), try graph.inDegree(target));
    try graph.validate();
}

test "tombstones: node pointing to multiple removed nodes has correct degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var removals: [8]graph_mod.NodeId = undefined;
    var survivors: [4]graph_mod.NodeId = undefined;
    for (0..8) |i| removals[i] = try graph.addNode();
    for (0..4) |i| survivors[i] = try graph.addNode();

    for (0..8) |i| try graph.addEdge(source, removals[i], 0, 0);
    for (0..4) |i| try graph.addEdge(source, survivors[i], 0, 0);

    for (0..8) |i| _ = try graph.removeNode(removals[i]);

    try testing.expectEqual(@as(usize, 4), try graph.outDegree(source));
    try graph.validate();
}

test "tombstones: validate correctly counts visible edges only" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(b, c, 0, 0);
    try graph.addEdge(c, a, 0, 0);

    _ = try graph.removeNode(b);
    try graph.validate();

    var it_a = try graph.neighbors(a);
    const a_neighbors = try graph_mod.materializeConsuming(&it_a, testing.allocator);
    defer testing.allocator.free(a_neighbors);
    try testing.expectEqual(@as(usize, 0), a_neighbors.len);

    var it_c = try graph.inNeighbors(c);
    const c_incoming = try graph_mod.materializeConsuming(&it_c, testing.allocator);
    defer testing.allocator.free(c_incoming);
    try testing.expectEqual(@as(usize, 0), c_incoming.len);
}

test "tombstones: neighbors returns empty when all destinations are removed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(source, a, 0, 0);
    try graph.addEdge(source, b, 0, 0);

    _ = try graph.removeNode(a);
    try graph.removeNode(b);

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
    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, target, 0, 0);
    try graph.addEdge(b, target, 0, 0);

    _ = try graph.removeNode(a);
    try graph.removeNode(b);

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
    for (0..sender_count) |i| senders[i] = try graph.addNode();
    for (0..sender_count) |i| try graph.addEdge(senders[i], hub, 0, 0);

    for (0..sender_count) |i| if (i % 2 == 0) _ = try graph.removeNode(senders[i]);

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
    for (0..10) |i| removals[i] = try graph.addNode();
    for (0..10) |i| try graph.addEdge(source, removals[i], 0, 0);

    for (0..10) |i| _ = try graph.removeNode(removals[i]);

    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try graph.validate();

    try graph.repairNode(source);
    try graph.validate();

    const after_adj = try graph.publishedNodeAdj(source);
    try testing.expect(!after_adj.flags.needs_repair_fwd);

    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "tombstones: debugValidate detects inconsistency if any" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    _ = try graph.removeNode(b);
    try graph.validate();

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "tombstones: hasNode returns false for removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);
    _ = try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
    try testing.expectError(error.InvalidNode, graph.neighbors(node));
}

test "tombstones: addEdge to removed destination fails" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(target);

    try testing.expectError(error.InvalidNode, graph.addEdge(source, target, 0, 0));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "tombstones: addEdge from removed source fails" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(source);

    try testing.expectError(error.InvalidNode, graph.addEdge(source, target, 0, 0));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}
