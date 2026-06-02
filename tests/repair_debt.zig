const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const types = test_internals.types;

const testing = std.testing;

fn addNodesForTest(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn fillBlock(graph: *graph_mod.Graph, block_index: u32, first_dst: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |i| {
        block.edges[i] = .{ .destination = first_dst + @as(u32, @intCast(i)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
}

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

test "repair debt: exactly MAX_GROUPS_PER_NODE groups does not trigger needs_repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 50);
    const node = graph_mod.NodeId{ .index = 0 };

    // Build 4 single-block groups (exactly MAX_GROUPS_PER_NODE).
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 64);
    fillBlock(&graph, b1, 65, 64);
    fillBlock(&graph, b2, 129, 64);
    fillBlock(&graph, b3, 193, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    const g3 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1, .next = g3 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b3, .count = 1, .next = constants.END_OF_CHAIN };

    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].block_count_fwd = 4;
    node_buffer.adj_buffers[0].group_count_fwd = 4;
    node_buffer.adj_buffers[0].first_group_fwd = g0;
    node_buffer.storePublishedAdjIndex(0);

    // updateRepairDebt must NOT flag this (4 <= MAX_GROUPS_PER_NODE).
    node_buffer.copyPublishedToStaging();
    const staging_adj = node_buffer.stagingAdj();
    test_internals.repair.updateRepairDebt(&graph.graph, staging_adj, node.index, .fwd);
    try testing.expect(!staging_adj.flags.needs_repair_fwd);
}

test "repair debt: repairBudgeted continues past stale queue entry" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 90);
    const n0 = graph_mod.NodeId{ .index = 0 };
    const n1 = graph_mod.NodeId{ .index = 1 };

    // n0: two underfull blocks → needs_repair
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 20);
    fillBlock(&graph, b1, 21, 20);
    var node0_buf = try graph.nodeAt(n0);
    node0_buf.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node0_buf.adj_buffers[0].first_block_fwd = b0;
    node0_buf.adj_buffers[0].block_count_fwd = 2;
    node0_buf.adj_buffers[0].flags.needs_repair_fwd = true;
    node0_buf.storePublishedAdjIndex(0);

    // n1: same setup, also needs_repair
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b2, 40, 20);
    fillBlock(&graph, b3, 60, 20);
    var node1_buf = try graph.nodeAt(n1);
    node1_buf.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node1_buf.adj_buffers[0].first_block_fwd = b2;
    node1_buf.adj_buffers[0].block_count_fwd = 2;
    node1_buf.adj_buffers[0].flags.needs_repair_fwd = true;
    node1_buf.storePublishedAdjIndex(0);

    // Queue: [n0, n1]
    try graph.graph.repair_fwd.append(graph.graph.allocator, n0.index);
    try graph.graph.repair_fwd.append(graph.graph.allocator, n1.index);

    // Repair n0 externally — leaves stale entry at head of queue
    try graph.repairNode(n0);

    // repairBudgeted(2) should skip stale n0 and repair n1
    const compacted = try graph.repairBudgeted(2);
    try testing.expect(compacted > 0);
    try testing.expect(!node1_buf.publishedAdj().flags.needs_repair_fwd);
}
