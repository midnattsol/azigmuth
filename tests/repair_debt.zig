const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const types = test_internals.types;

const testing = std.testing;

test "repair debt: needs_repair flag is cleared after repairNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    // Create two under-full blocks on the same node to trigger a merge.
    const source = try graph.addNode();
    for (0..83) |_| {
        _ = try graph.addNode();
    }

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    var first_block_edges = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);

    for (0..47) |edge_index| {
        first_block_edges.edges[edge_index] = types.Edge{ .destination = @intCast(edge_index + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_block_edges.mask = constants.denseMask(47);
    for (0..36) |edge_index| {
        second_block_edges.edges[edge_index] = types.Edge{ .destination = @intCast(edge_index + 48), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    second_block_edges.mask = constants.denseMask(36);

    var node_buffer = try graph.nodeAt(source);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].first_block_fwd = block0;
    node_buffer.adj_buffers[0].block_count_fwd = 2;
    node_buffer.adj_buffers[0].flags.needs_repair_fwd = true;
    node_buffer.storePublishedAdjIndex(0);

    // Verify flag is set before repair.
    try testing.expect(node_buffer.publishedAdj().flags.needs_repair_fwd);

    // Trigger repair via the private module.
    _ = try test_internals.repair.repairNodeSide(&graph.graph, source, .fwd);

    // After repair, the flag must be cleared.
    try testing.expect(!node_buffer.publishedAdj().flags.needs_repair_fwd);
}

test "repair debt: updateRepairDebt sets flag when block drops below occupancy" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    // Manually construct a two-block forward adjacency where the first
    // (non-tail) block has only 20 edges — well below MIN_OCCUPANCY (48).
    // updateRepairDebt must detect this and set needs_repair_fwd.
    const source = try graph.addNode();
    for (0..40) |_| {
        _ = try graph.addNode();
    }

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();

    var first_block_edges = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    for (0..20) |edge_index| {
        first_block_edges.edges[edge_index] = types.Edge{ .destination = @intCast(edge_index + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_block_edges.mask = constants.denseMask(20);

    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);
    for (0..32) |edge_index| {
        second_block_edges.edges[edge_index] = types.Edge{ .destination = @intCast(edge_index + 21), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    second_block_edges.mask = constants.denseMask(32);

    var node_buffer = try graph.nodeAt(source);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].first_block_fwd = block0;
    node_buffer.adj_buffers[0].block_count_fwd = 2;
    node_buffer.storePublishedAdjIndex(0);

    // Before updateRepairDebt the flag must be clear.
    try testing.expect(!node_buffer.publishedAdj().flags.needs_repair_fwd);

    // updateRepairDebt scans non-tail blocks and sets the flag.
    test_internals.repair.updateRepairDebt(&graph.graph, &node_buffer.adj_buffers[0], source.index, .fwd);

    // The flag must be set because block0 (non-tail) is below MIN_OCCUPANCY.
    try testing.expect(node_buffer.adj_buffers[0].flags.needs_repair_fwd);
}

test "repair debt: updateRepairDebt does not set flag when only tail block is underfull" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_count: usize = 130;
    var destinations: [destination_count]graph_mod.NodeId = undefined;

    for (0..destination_count) |destination_index| {
        destinations[destination_index] = try graph.addNode();
        try graph.addEdge(source, destinations[destination_index], 0, 0);
    }

    // Remove edges from the tail block until it's underfull. The tail is exempt.
    for (0..2) |destination_index| {
        try testing.expect(try graph.removeEdge(source, destinations[destination_count - 1 - destination_index]));
    }
    try graph.validate();

    const node_buffer = try graph.nodeAtConst(source);
    // Tail underfill should NOT set needs_repair.
    try testing.expect(!node_buffer.publishedAdj().flags.needs_repair_fwd);
}

test "repair: repairNode with zero or one block returns zero compacted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.addNode();

    // No blocks → compacted should be 0.
    const compacted_empty = try test_internals.repair.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted_empty);

    // Add one block, still no merge possible.
    try graph.addEdge(node, .{ .index = 1 }, 0, 0);
    const compacted_single = try test_internals.repair.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted_single);
}

test "repair: repairBudgeted with max_steps zero returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const compacted = try test_internals.repair.repairBudgeted(&graph.graph, 0);
    try testing.expectEqual(@as(usize, 0), compacted);
}
