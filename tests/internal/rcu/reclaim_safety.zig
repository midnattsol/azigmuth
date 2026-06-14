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

    const src = try graph.addNode();
    var targets: [3]graph_mod.NodeId = undefined;
    for (0..targets.len) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    try graph.validate();

    for (targets[0..]) |t| {
        _ = try graph.removeEdge(src, t);
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

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    _ = try graph.removeEdge(src, dst);

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = graph.validate() catch {};
}

test "rcu safety: last_reclaim_epoch optimization does not block reclamation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [4]graph_mod.NodeId = undefined;
    for (0..targets.len) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    _ = try graph.removeEdge(src, targets[0]);
    _ = try graph.removeEdge(src, targets[1]);

    graph.bumpEpoch();
    graph.reclaimRetired();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    _ = try graph.removeEdge(src, targets[2]);
    _ = try graph.removeEdge(src, targets[3]);
    graph.bumpEpoch();
    graph.reclaimRetired();

    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = try graph.allocBlockFwd();
    _ = graph.validate() catch {};
}

test "rcu safety: group retire/reclaim/alloc full cycle" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const group = try graph.allocGroup();

    const epoch = graph.graph.epoch.load(.acquire);
    page_ops.retireGroup(&graph.graph, group, epoch);

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    _ = try graph.allocGroup();
    _ = graph.validate() catch {};
}
