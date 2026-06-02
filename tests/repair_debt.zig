const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const types = test_internals.types;
const helpers = @import("helpers.zig");

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

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination_index: u32, source_index: u32) !void {
    const block_index = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    block.sources[0] = source_index;
    block.mask = constants.denseMask(1);

    var node_buffer = try graph.nodeAt(.{ .index = destination_index });
    helpers.publishedRevSide(node_buffer).first_block = block_index;
    helpers.publishedRevSide(node_buffer).block_count = 1;
    node_buffer.degree_rev = 1;
}

fn publishReverseSourcesForForwardRange(graph: *graph_mod.Graph, source_index: u32, first_destination: u32, count: u7) !void {
    for (0..count) |offset| {
        try publishSingleReverseSource(graph, first_destination + @as(u32, @intCast(offset)), source_index);
    }
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
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = block0;
    helpers.publishedFwdSide(node_buffer).block_count = 2;
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });

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
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = block0;
    helpers.publishedFwdSide(node_buffer).block_count = 2;

    // Before updateRepairDebt the flag must be clear.
    try testing.expect(!node_buffer.publishedAdj().flags.needs_repair_fwd);

    // updateRepairDebt scans non-tail blocks and sets the flag.
    var adj = node_buffer.publishedAdj();
    test_internals.repair.updateRepairDebt(&graph.graph, &adj, source.index, .fwd);
    helpers.setPublishedAdjSnapshot(node_buffer, adj);

    // The flag must be set because block0 (non-tail) is below MIN_OCCUPANCY.
    try testing.expect(node_buffer.publishedAdj().flags.needs_repair_fwd);
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

test "repair debt: grouped non-tail runs below 4 blocks trigger repair debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 130);
    const node = graph_mod.NodeId{ .index = 0 };

    const b0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 64);
    fillBlock(&graph, b2, 65, 64);
    fillBlock(&graph, b4, 129, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1, .next = constants.END_OF_CHAIN };

    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 3;
    helpers.publishedFwdSide(node_buffer).group_count = 3;
    helpers.publishedFwdSide(node_buffer).first_group = g0;
    node_buffer.degree_fwd = 129;

    var staging_adj = node_buffer.publishedAdj();
    test_internals.repair.updateRepairDebt(&graph.graph, &staging_adj, node.index, .fwd);
    try testing.expect(staging_adj.flags.needs_repair_fwd);
}

test "repair debt: validate requires run fragmentation debt to be marked" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 130);
    const node = graph_mod.NodeId{ .index = 0 };

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();
    page_ops.freeBlock(&graph.graph, b1, .fwd);
    page_ops.freeBlock(&graph.graph, b3, .fwd);
    fillBlock(&graph, b0, 1, 64);
    fillBlock(&graph, b2, 65, 64);
    fillBlock(&graph, b4, 129, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1, .next = constants.END_OF_CHAIN };

    try publishReverseSourcesForForwardRange(&graph, node.index, 1, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 65, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 129, 1);

    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 3;
    helpers.publishedFwdSide(node_buffer).group_count = 3;
    helpers.publishedFwdSide(node_buffer).first_group = g0;
    node_buffer.degree_fwd = 129;
    graph.graph.edge_count.store(129, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());

    var staging_adj = node_buffer.publishedAdj();
    staging_adj.flags.needs_repair_fwd = true;
    helpers.setPublishedAdjSnapshot(node_buffer, staging_adj);
    try graph.validate();
}

test "repair debt: contiguous MAX_GROUPS_PER_NODE groups trigger canonical repair debt" {
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
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 4;
    helpers.publishedFwdSide(node_buffer).group_count = 4;
    helpers.publishedFwdSide(node_buffer).first_group = g0;

    // Even at exactly MAX_GROUPS_PER_NODE, a fully contiguous grouped chain
    // should be canonicalized back to contiguous representation.
    var staging_adj = node_buffer.publishedAdj();
    test_internals.repair.updateRepairDebt(&graph.graph, &staging_adj, node.index, .fwd);
    try testing.expect(staging_adj.flags.needs_repair_fwd);
}

test "repair debt: repairNode canonicalizes grouped contiguous layout even when occupancy is fine" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 130);
    const node = graph_mod.NodeId{ .index = 0 };

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 64);
    fillBlock(&graph, b1, 65, 64);
    fillBlock(&graph, b2, 129, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1, .next = constants.END_OF_CHAIN };

    try publishReverseSourcesForForwardRange(&graph, node.index, 1, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 65, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 129, 1);

    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = b0;
    helpers.publishedFwdSide(node_buffer).block_count = 3;
    helpers.publishedFwdSide(node_buffer).group_count = 3;
    helpers.publishedFwdSide(node_buffer).first_group = g0;
    node_buffer.degree_fwd = 129;
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    graph.graph.edge_count.store(129, .release);

    try graph.repairNode(node);
    try graph.validate();

    const repaired = try graph.publishedNodeAdj(node);
    try testing.expectEqual(@as(u16, 0), repaired.group_count_fwd);
    try testing.expectEqual(@as(u16, 3), repaired.block_count_fwd);
    try testing.expect(!repaired.flags.needs_repair_fwd);
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
    const node0_buf = try graph.nodeAt(n0);
    helpers.clearPublishedSides(node0_buf);
    helpers.publishedFwdSide(node0_buf).first_block = b0;
    helpers.publishedFwdSide(node0_buf).block_count = 2;
    helpers.setPublishedFlags(node0_buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });

    // n1: same setup, also needs_repair
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b2, 40, 20);
    fillBlock(&graph, b3, 60, 20);
    var node1_buf = try graph.nodeAt(n1);
    helpers.clearPublishedSides(node1_buf);
    helpers.publishedFwdSide(node1_buf).first_block = b2;
    helpers.publishedFwdSide(node1_buf).block_count = 2;
    helpers.setPublishedFlags(node1_buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });

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

test "repair debt: updateRepairDebt marks single-block tombstone debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed, 0, 0);
    try graph.removeNode(removed);

    var source_buffer = try graph.nodeAt(source);
    var staging_adj = source_buffer.publishedAdj();
    test_internals.repair.updateRepairDebt(&graph.graph, &staging_adj, source.index, .fwd);

    try testing.expect(staging_adj.flags.needs_repair_fwd);
}

test "repair debt: repairBudgeted skips removed queue entries and still compacts tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed, 0, 0);
    try graph.removeNode(removed);

    try graph.graph.repair_fwd.append(graph.graph.allocator, removed.index);

    const compacted = try graph.repairBudgeted(1);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "repair debt: repairNode canonicalizes single-block grouped contiguous adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 3);

    const b0 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 1);

    const g0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = constants.END_OF_CHAIN };

    // Reverse backlink so forward/reverse consistency holds.
    const rb = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, rb, .rev).sources[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, rb, .rev).mask = constants.denseMask(1);
    {
        const d1 = try graph.nodeAt(.{ .index = 1 });
        helpers.clearPublishedSides(d1);
        helpers.publishedRevSide(d1).first_block = rb;
        helpers.publishedRevSide(d1).block_count = 1;
        d1.degree_rev = 1;
    }

    const node = try graph.nodeAt(.{ .index = 0 });
    helpers.clearPublishedSides(node);
    helpers.publishedFwdSide(node).first_block = b0;
    helpers.publishedFwdSide(node).block_count = 1;
    helpers.publishedFwdSide(node).group_count = 1;
    helpers.publishedFwdSide(node).first_group = g0;
    node.degree_fwd = 1;
    helpers.setPublishedFlags(node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    graph.graph.edge_count.store(1, .release);

    try graph.repairNode(.{ .index = 0 });
    try graph.validate();

    const repaired = (try graph.nodeAtConst(.{ .index = 0 })).publishedAdj();
    try testing.expectEqual(@as(u16, 0), repaired.group_count_fwd);
    try testing.expectEqual(@as(u16, 1), repaired.block_count_fwd);
    try testing.expect(!repaired.flags.needs_repair_fwd);
}
