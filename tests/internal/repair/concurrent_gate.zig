//! Deterministic coverage of the single-repairer gate. The public contract
//! ("ConcurrentMutation while another repairer is active") used to be tested
//! by racing two threads, which was flaky: if the scheduler serialized them,
//! both calls succeeded. Holding `active_repairers` directly tests the same
//! contract without depending on thread timing.

const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

fn addRepairDebt(graph: *graph_mod.Graph) !void {
    // removeNode leaves flagged forward-tombstone debt on every predecessor,
    // so the repair entry points have real work queued.
    var predecessors: [4]graph_mod.NodeId = undefined;
    for (0..predecessors.len) |i| predecessors[i] = try graph.addNode();
    const hub = try graph.addNode();
    for (predecessors) |predecessor| try graph.addEdge(predecessor, hub, 0, 0);
    _ = try graph.removeNode(hub);
}

test "repairBudgeted returns ConcurrentMutation while another repairer holds the gate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addRepairDebt(&graph);

    graph.graph.active_repairers.store(1, .release);
    try testing.expectError(error.ConcurrentMutation, graph.repairBudgeted(10));
    graph.graph.active_repairers.store(0, .release);

    // Once the gate is free the same call succeeds and pays the queued debt.
    _ = try graph.repairBudgeted(10);
    try graph.validate();
}

test "flushRepairs returns ConcurrentMutation while another repairer holds the gate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addRepairDebt(&graph);

    graph.graph.active_repairers.store(1, .release);
    try testing.expectError(error.ConcurrentMutation, graph.flushRepairs());
    graph.graph.active_repairers.store(0, .release);

    _ = try graph.flushRepairs();
    try graph.validate();
}

test "repair gate is released after a successful pass" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addRepairDebt(&graph);

    _ = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_repairers.load(.acquire));

    _ = try graph.flushRepairs();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_repairers.load(.acquire));
}
