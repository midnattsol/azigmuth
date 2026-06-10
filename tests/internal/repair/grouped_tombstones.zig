const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const testing = std.testing;

test "repair: repairNode clears forward tombstones from grouped adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [200]graph_mod.NodeId = undefined;
    for (0..200) |i| {
        destinations[i] = try graph.addNode();
        try graph.addEdge(source, destinations[i], 0, 0);
    }

    // Create a fragmented forward layout by removing from a large adjacency.
    _ = try graph.removeEdge(source, destinations[199]);

    var source_adj = try graph.publishedNodeAdj(source);
    try testing.expect(source_adj.block_count_fwd > 1 or source_adj.group_count_fwd > 0);

    // Create tombstones: remove destinations in different original blocks.
    _ = try graph.removeNode(destinations[64]);
    _ = try graph.removeNode(destinations[128]);

    source_adj = try graph.publishedNodeAdj(source);
    try testing.expect(source_adj.flags.needs_repair_fwd);

    _ = try graph.repairNode(source);
    try graph.validate();

    // Tombstones must be absent from iteration after repair.
    var iter = try graph.neighbors(source);
    defer iter.deinit();
    while (iter.next()) |neighbor| {
        try testing.expect(neighbor.index != destinations[64].index);
        try testing.expect(neighbor.index != destinations[128].index);
    }

    // Note: needs_repair_fwd may still be set after repairNode.
    // The rebuild removes tombstones and packs edges into freshly
    // allocated blocks, but fresh blocks from the retired/free stack
    // are not guaranteed contiguous.  Non-contiguous fresh blocks
    // create EdgeBlockGroup chains, which trigger needs_repair via the
    // run fragmentation bound (RFC §3.2).
    // This is a genuine design limitation: repair rebuilds do not
    // (currently) compact blocks into a physically contiguous range.
}

test "repair: repairBudgeted discovers grouped forward tombstone debt without explicit repairNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [130]graph_mod.NodeId = undefined;
    for (0..130) |i| {
        destinations[i] = try graph.addNode();
        try graph.addEdge(source, destinations[i], 0, 0);
    }

    // Trigger COW on non-tail block via removeEdge.
    _ = try graph.removeEdge(source, destinations[129]);

    // Create tombstones via removeNode.
    const extra = try graph.addNode();
    try graph.addEdge(source, extra, 0, 0);
    _ = try graph.removeNode(extra);

    const source_adj = try graph.publishedNodeAdj(source);
    try testing.expect(source_adj.flags.needs_repair_fwd);

    // Clear repair queues so only flag discovery works.
    graph.graph.repair_fwd.clearRetainingCapacity();
    graph.graph.repair_rev.clearRetainingCapacity();

    // repairBudgeted must discover grouped tombstone debt via the flag alone.
    const repaired = try graph.repairBudgeted(1);
    try testing.expectEqual(@as(usize, 1), repaired);
    try graph.validate();

    // Tombstones must be absent after repair.
    var iter = try graph.neighbors(source);
    defer iter.deinit();
    while (iter.next()) |neighbor| {
        try testing.expect(neighbor.index != extra.index);
    }
}
