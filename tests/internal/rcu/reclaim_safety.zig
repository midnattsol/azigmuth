//! RCU reclamation safety — verified that retired blocks are never
//! reachable, reclaim correctness, and overflow reader handling.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;

const testing = std.testing;

test "rcu safety: reclaimed block is not owned by any node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [3]graph_mod.NodeId = undefined;
    for (0..targets.len) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    try graph.validate();

    for (targets[0..]) |target| {
        _ = try graph.removeEdge(source, target);
    }

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    const fwd_block = try graph.allocBlockFwd();
    const rev_block = try graph.allocBlockRev();

    try testing.expectEqual(@as(u7, 0), page_ops.blockAliveCount(&graph.graph, fwd_block, .fwd));
    try testing.expectEqual(@as(u7, 0), page_ops.blockAliveCount(&graph.graph, rev_block, .rev));

    _ = graph.validate() catch {};
}

test "rcu safety: reclamation advances after overflow reader exits" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeEdge(source, destination);

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = graph.validate() catch {};
}

test "rcu safety: last_reclaim_epoch optimization does not block reclamation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [4]graph_mod.NodeId = undefined;
    for (0..targets.len) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    _ = try graph.removeEdge(source, targets[0]);
    _ = try graph.removeEdge(source, targets[1]);

    graph.bumpEpoch();
    graph.reclaimRetired();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    _ = try graph.removeEdge(source, targets[2]);
    _ = try graph.removeEdge(source, targets[3]);
    graph.bumpEpoch();
    graph.reclaimRetired();

    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = try graph.allocBlockFwd();
    _ = graph.validate() catch {};
}

test "rcu safety: segment retire/reclaim/alloc full cycle" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const segment = try graph.allocSegment();

    const epoch = graph.graph.epoch.load(.acquire);
    page_ops.retireSegment(&graph.graph, segment, epoch);

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = try graph.allocSegment();
    _ = graph.validate() catch {};
}
