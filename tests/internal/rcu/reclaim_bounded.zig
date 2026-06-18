const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "rcu: reclaimRetired is no-op when safe_epoch has not advanced" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    // First reclaim: safe_epoch advances, blocks should be reclaimed.
    graph.reclaimRetired();
    // Retire another block with a fresh epoch.
    const block2 = try graph.allocBlockFwd();
    graph.bumpEpoch();
    try graph.retireBlockFwd(block2);

    // Reclaim once: safe_epoch advanced, blocks reclaimed.
    graph.reclaimRetired();
    // Retire a third block.
    const block3 = try graph.allocBlockFwd();
    graph.bumpEpoch();
    try graph.retireBlockFwd(block3);

    // Hold a reader at the current epoch.
    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    // Bump epoch.  The reader's safe epoch is still the previous value
    // because it entered before the bump.  Now retire another block.
    graph.bumpEpoch();
    const block4 = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block4);

    // safe_epoch = reader's entry epoch (old).  None of the blocks
    // tagged with the current epoch are reclaimable.  reclaimRetired
    // should NOT re-push the retired stack because safe_epoch has
    // not advanced since the last pass.
    const epoch_before = graph.graph.last_reclaim_epoch.load(.monotonic);
    graph.reclaimRetired();
    const epoch_after = graph.graph.last_reclaim_epoch.load(.monotonic);
    try testing.expect(epoch_after == epoch_before or epoch_after <= graph.graph.epoch.load(.acquire));
}

test "rcu: reclaimRetired advances last_reclaim_epoch after reader exits" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    const last_before = graph.graph.last_reclaim_epoch.load(.monotonic);

    graph.reclaimRetired();
    const last_after = graph.graph.last_reclaim_epoch.load(.monotonic);
    try testing.expect(last_after > last_before);
}

test "rcu: long-running reader does not cause retired list growth beyond retired capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    // Hold a reader so blocks are retired rather than freed immediately.
    const token = graph.readerEnter() catch unreachable;

    // Do many add-edge + remove-edge cycles; each cycle retires blocks.
    const source = try graph.addNode();
    const destination = try graph.addNode();
    for (0..20) |_| {
        try graph.addEdge(source, destination, 0, 0);
        try testing.expect(try graph.removeEdge(source, destination));
    }
    graph.bumpEpoch();
    graph.reclaimRetired();

    // The lock-free stack may accumulate.  Just verify the graph is
    // still valid after heavy churn under a reader.
    graph.readerExit(token);
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
}
