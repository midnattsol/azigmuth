//! Embedded-profile smoke tests. The build wires this runner's `graph_mod`
//! facade to the `embedded` build-option preset, so the whole azigmuth
//! compilation in this binary uses it: tiny fixed footprint, small ceilings,
//! 8 reader slots.

const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "embedded profile: constants derive from the override" {
    const constants = graph_mod.constants_mod;
    try testing.expectEqual(@as(usize, 8), constants.MAX_READER_SLOTS);
    try testing.expectEqual(@as(usize, 16), constants.EDGE_BLOCK_DIR.l1);
    try testing.expectEqual(@as(usize, 16), constants.EDGE_BLOCK_DIR.l2);
    // 4 inline + 16×16 lazy pages of 64 blocks; ×16 edges → ≈266K edge ceiling.
    try testing.expectEqual(@as(u64, (4 + 16 * 16) * 64), constants.MAX_TOTAL_BLOCKS_PER_POOL);

    // Block16: capacity, 75% floor, and block sizes all derive together.
    try testing.expectEqual(@as(u7, 16), constants.EDGES_PER_BLOCK);
    try testing.expectEqual(@as(u7, 12), constants.MIN_OCCUPANCY);
    try testing.expectEqual(@as(usize, 128), @sizeOf(graph_mod.types_mod.EdgeBlockFwd));
    try testing.expectEqual(@as(usize, 64), @sizeOf(graph_mod.types_mod.EdgeBlockRev));
}

test "embedded profile: multi-block adjacency works end to end on 16-edge blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [100]graph_mod.NodeId = undefined;
    for (0..destinations.len) |destination_idx| destinations[destination_idx] = try graph.addNode();
    // ~7 blocks of 16 after tiny promotion.
    for (destinations) |destination| try graph.addEdge(source, destination, 0, 0);
    try testing.expectEqual(@as(usize, destinations.len), try graph.outDegree(source));

    // Tail removals + repair keep the 12/16 occupancy floor honest. With
    // 16-edge blocks the segment-fragmentation bound trips sooner, so follow the
    // documented contract: repair the node and retry on RepairRequired.
    var removed: usize = 0;
    for (destinations[destinations.len - 10 ..]) |destination| {
        const was_removed = graph.removeEdge(source, destination) catch |err| switch (err) {
            error.RepairRequired => blk: {
                _ = try graph.repairNode(source);
                break :blk try graph.removeEdge(source, destination);
            },
            else => return err,
        };
        if (was_removed) removed += 1;
    }
    try testing.expectEqual(@as(usize, 10), removed);
    _ = try graph.repairNode(source);
    try testing.expectEqual(@as(usize, destinations.len - 10), try graph.outDegree(source));
    try graph.validate();
}

test "embedded profile: graph operations work end to end" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [300]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

    // Fan-out past the tiny cap and across block boundaries.
    for (nodes[1..]) |destination| {
        try graph.addEdge(nodes[0], destination, 0, 0);
    }
    try testing.expectEqual(@as(usize, nodes.len - 1), try graph.outDegree(nodes[0]));

    try testing.expect(try graph.removeEdge(nodes[0], nodes[1]));
    try testing.expectEqual(@as(usize, nodes.len - 2), try graph.outDegree(nodes[0]));
    try graph.validate();
}

test "embedded profile: readers beyond the slot pool fall back or fail closed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    // 8 precise slots + 8 tracked overflow tokens: 16 concurrent iterators
    // must be accepted; the 17th must fail closed with GraphBusy.
    var iterators: [16]graph_mod.query_mod.NeighborIterator = undefined;
    var opened: usize = 0;
    defer for (iterators[0..opened]) |*it| it.deinit();

    while (opened < iterators.len) : (opened += 1) {
        iterators[opened] = try graph.neighbors(source);
    }
    try testing.expectError(error.GraphBusy, graph.neighbors(source));
}

test "embedded profile: GraphCore fixed footprint stays small" {
    try testing.expect(@sizeOf(graph_mod.GraphCore) < 4 * 1024);
}
