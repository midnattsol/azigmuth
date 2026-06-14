const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const testing = std.testing;

test "repair debt: needs_repair flag alone is sufficient for repairBudgeted discovery" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    _ = try publish.ensureForwardBlockLayout(&graph, source);
    _ = try graph.removeNode(destination);

    graph.graph.repair_fwd.clearRetainingCapacity();
    graph.graph.repair_rev.clearRetainingCapacity();

    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired > 0);
    try graph.validate();
}

test "repair debt: repairBudgeted repairs without implicit reclaim" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    _ = try publish.ensureForwardBlockLayout(&graph, source);
    _ = try graph.removeNode(destination);

    // Clear any retired memory from removeNode so the assertion
    // below only observes the explicit repair pass.
    graph.reclaimRetired();

    const free_head_before = graph.graph.free_blocks_fwd_head.load(.acquire);
    const retired_head_before = graph.graph.retired_blocks_fwd_head.load(.acquire);

    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired > 0);
    try graph.validate();

    const free_head_after_repair = graph.graph.free_blocks_fwd_head.load(.acquire);
    try testing.expectEqual(free_head_before, free_head_after_repair);
    _ = retired_head_before;

    graph.reclaimRetired();
}

test "repair debt: stale entries in repair queue do not break repairBudgeted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    _ = try graph.removeNode(destination);

    try graph.graph.repair_fwd.append(graph.graph.allocator, 99999);
    try graph.graph.repair_rev.append(graph.graph.allocator, 99998);

    const repaired = try graph.repairBudgeted(5);
    try testing.expect(repaired > 0);
    try graph.validate();
}

test "repair debt: repairBudgeted ignores removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    _ = try graph.addNode();

    _ = try graph.removeNode(source);
    try graph.graph.repair_fwd.append(graph.graph.allocator, source.index);

    const repaired = try graph.repairBudgeted(5);
    try testing.expectEqual(@as(usize, 1), repaired);
    try graph.validate();
}

test "repair debt: updateRepairDebtSide flags forward tombstones immediately after removeNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeNode(destination);

    const source_meta = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
    try testing.expect(source_meta.needs_repair_fwd);
    try graph.validate();
}

test "repair debt: no-op repairBudgeted returns 0 when no debt exists" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair debt: repairBudgeted with max_nodes = 0 repairs nothing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try graph.validate();
    const repaired = try graph.repairBudgeted(0);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair debt: repairBudgeted processes queued repair debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..83) |_| {
        _ = try graph.addNode();
    }

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    var first_block_edges = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);

    for (0..47) |edge_idx| {
        first_block_edges.destinations[edge_idx] = @intCast(edge_idx + 1);
        first_block_edges.relations[edge_idx] = 0;
        first_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block0, .fwd, @intCast(47));
    for (0..36) |edge_idx| {
        second_block_edges.destinations[edge_idx] = @intCast(edge_idx + 48);
        second_block_edges.relations[edge_idx] = 0;
        second_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block1, .fwd, @intCast(36));

    const node = try graph.nodeAt(source);
    publish.clearPublishedSides(node);
    publish.publishedFwdSide(node).first_block = block0;
    publish.publishedFwdSide(node).block_count = 2;
    publish.setPublishedFlags(node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(83)));
    try publish.syncToPublished(&graph, source.index);
    try publishReverseSourcesForForwardRange(&graph, source.index, 1, 47);
    try publishReverseSourcesForForwardRange(&graph, source.index, 48, 36);
    graph.graph.edge_count.store(83, .release);
    try graph.graph.repair_fwd.append(graph.graph.allocator, source.index);

    const compacted = try graph.repairBudgeted(1);
    try testing.expect(compacted > 0);
    try testing.expectEqual(@as(usize, 0), graph.graph.repair_fwd.items.len);
    try graph.validate();
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(source));
}

fn addNodesForTest(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn fillBlock(graph: *graph_mod.Graph, block_idx: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    for (0..count) |i| {
        block.destinations[i] = first_destination + @as(u32, @intCast(i));
        block.relations[i] = 0;
        block.flags[i] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .fwd, @intCast(count));
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination_idx: u32, source_idx: u32) !void {
    const block_idx = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    block.sources[0] = source_idx;
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .rev, @intCast(1));

    const node_buffer = try graph.nodeAt(.{ .index = destination_idx });
    publish.publishedRevSide(node_buffer).first_block = block_idx;
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, destination_idx);
}

fn publishReverseSourcesForForwardRange(graph: *graph_mod.Graph, source_idx: u32, first_destination: u32, count: u7) !void {
    for (0..count) |offset| {
        try publishSingleReverseSource(graph, first_destination + @as(u32, @intCast(offset)), source_idx);
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

    for (0..47) |edge_idx| {
        first_block_edges.destinations[edge_idx] = @intCast(edge_idx + 1);
        first_block_edges.relations[edge_idx] = 0;
        first_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block0, .fwd, @intCast(47));
    for (0..36) |edge_idx| {
        second_block_edges.destinations[edge_idx] = @intCast(edge_idx + 48);
        second_block_edges.relations[edge_idx] = 0;
        second_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block1, .fwd, @intCast(36));

    const node_buffer = try graph.nodeAt(source);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = block0;
    publish.publishedFwdSide(node_buffer).block_count = 2;
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });

    // Verify flag is set before repair.
    try testing.expect(node_buffer.publishedAdj().flags.needs_repair_fwd);

    // Trigger repair via the private module.
    _ = try graph_mod.repair_mod.repairNodeSide(&graph.graph, source, .fwd);

    // After repair, the flag must be cleared.
    try testing.expect(!(try graph.publishedNodeAdj(source)).flags.needs_repair_fwd);
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
    for (0..20) |edge_idx| {
        first_block_edges.destinations[edge_idx] = @intCast(edge_idx + 1);
        first_block_edges.relations[edge_idx] = 0;
        first_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block0, .fwd, @intCast(20));

    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);
    for (0..32) |edge_idx| {
        second_block_edges.destinations[edge_idx] = @intCast(edge_idx + 21);
        second_block_edges.relations[edge_idx] = 0;
        second_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block1, .fwd, @intCast(32));

    const node_buffer = try graph.nodeAt(source);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = block0;
    publish.publishedFwdSide(node_buffer).block_count = 2;

    // Before updateRepairDebt the flag must be clear.
    try testing.expect(!node_buffer.publishedAdj().flags.needs_repair_fwd);

    // updateRepairDebt scans non-tail blocks and sets the flag.
    var adj = node_buffer.publishedAdj();
    graph_mod.repair_mod.updateRepairDebt(&graph.graph, &adj, source.index, .fwd);
    publish.setPublishedAdjSnapshot(node_buffer, adj);

    // The flag must be set because block0 (non-tail) is below MIN_OCCUPANCY.
    try testing.expect(node_buffer.publishedAdj().flags.needs_repair_fwd);
}

test "repair debt: tail underfill remains logically valid and repair-safe" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_count: usize = 130;
    var destinations: [destination_count]graph_mod.NodeId = undefined;

    for (0..destination_count) |destination_idx| {
        destinations[destination_idx] = try graph.addNode();
        try graph.addEdge(source, destinations[destination_idx], 0, 0);
    }

    // Remove edges from the tail block until it's underfull. The tail is exempt.
    for (0..2) |destination_idx| {
        try testing.expect(try graph.removeEdge(source, destinations[destination_count - 1 - destination_idx]));
    }
    try graph.validate();

    // Hot-path mutation may conservatively leave needs_repair_fwd set even
    // when only tail underfill occurred. Repair must preserve logical
    // correctness, but a grouped non-contiguous rebuild may still carry debt.
    _ = try graph.repairNode(source);
    const node_buffer = try graph.nodeAt(source);
    try testing.expectEqual(@as(usize, destination_count - 2), try graph.outDegree(source));
    try graph.validate();
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    _ = node_buffer;
}

test "repair: repairNode with zero or one block returns zero compacted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.addNode();

    // No blocks → compacted should be 0.
    const compacted_empty = try graph_mod.repair_mod.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted_empty);

    // Add one block, still no merge possible.
    try graph.addEdge(node, .{ .index = 1 }, 0, 0);
    const compacted_single = try graph_mod.repair_mod.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted_single);
}

test "repair: repairBudgeted with max_steps zero returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const compacted = try graph_mod.repair_mod.repairBudgeted(&graph.graph, 0);
    try testing.expectEqual(@as(usize, 0), compacted);
}

test "repair debt: grouped non-tail runs below 4 blocks are valid layout" {
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
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 3;
    publish.publishedFwdSide(node_buffer).group_count = 3;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(129)));

    var staging_adj = node_buffer.publishedAdj();
    graph_mod.repair_mod.updateRepairDebt(&graph.graph, &staging_adj, node.index, .fwd);
    try testing.expect(!staging_adj.flags.needs_repair_fwd);
}

test "repair debt: validate accepts run fragmentation without repair flag" {
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
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1 };

    try publishReverseSourcesForForwardRange(&graph, node.index, 1, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 65, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 129, 1);

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 3;
    publish.publishedFwdSide(node_buffer).group_count = 3;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(129)));
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(129, .release);

    try graph.validate();
}

test "repair debt: contiguous MAX_GROUPS_PER_NODE groups do not trigger canonical repair debt" {
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
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g3).* = .{ .start = b3, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 4;
    publish.publishedFwdSide(node_buffer).group_count = 4;
    publish.publishedFwdSide(node_buffer).first_group = g0;

    var staging_adj = node_buffer.publishedAdj();
    graph_mod.repair_mod.updateRepairDebt(&graph.graph, &staging_adj, node.index, .fwd);
    try testing.expect(!staging_adj.flags.needs_repair_fwd);
}

test "repair debt: repairNode canonicalizes grouped contiguous layout preventively" {
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
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };

    try publishReverseSourcesForForwardRange(&graph, node.index, 1, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 65, 64);
    try publishReverseSourcesForForwardRange(&graph, node.index, 129, 1);

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = b0;
    publish.publishedFwdSide(node_buffer).block_count = 3;
    publish.publishedFwdSide(node_buffer).group_count = 3;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(129)));
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(129, .release);

    // Explicit repairNode performs preventive canonicalization: the grouped
    // layout is rebuilt into a compact form and the work is reported.
    const summary = try graph.repairNode(node);
    try testing.expect(summary.repaired_fwd);
    try testing.expect(summary.had_flagged_debt_fwd);
    try graph.validate();

    const repaired = try graph.publishedNodeAdj(node);
    try testing.expectEqual(@as(u32, 3), repaired.block_count_fwd);
    try testing.expect(!repaired.flags.removed);
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
    publish.clearPublishedSides(node0_buf);
    publish.publishedFwdSide(node0_buf).first_block = b0;
    publish.publishedFwdSide(node0_buf).block_count = 2;
    publish.setPublishedFlags(node0_buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, n0.index);

    // n1: same setup, also needs_repair
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b2, 40, 20);
    fillBlock(&graph, b3, 60, 20);
    const node1_buf = try graph.nodeAt(n1);
    publish.clearPublishedSides(node1_buf);
    publish.publishedFwdSide(node1_buf).first_block = b2;
    publish.publishedFwdSide(node1_buf).block_count = 2;
    publish.setPublishedFlags(node1_buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, n1.index);

    // Queue: [n0, n1]
    try graph.graph.repair_fwd.append(graph.graph.allocator, n0.index);
    try graph.graph.repair_fwd.append(graph.graph.allocator, n1.index);

    // Repair n0 externally — leaves stale entry at head of queue
    _ = try graph.repairNode(n0);

    // repairBudgeted(2) should skip stale n0 and repair n1
    const compacted = try graph.repairBudgeted(2);
    try testing.expect(compacted > 0);
    try testing.expect(!(try graph.publishedNodeAdj(n1)).flags.needs_repair_fwd);
}

test "repair debt: updateRepairDebt marks single-block tombstone debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed, 0, 0);
    _ = try graph.removeNode(removed);

    const source_buffer = try graph.nodeAt(source);
    _ = source_buffer;
    var staging_adj = try graph.publishedNodeAdj(source);
    graph_mod.repair_mod.updateRepairDebt(&graph.graph, &staging_adj, source.index, .fwd);

    try testing.expect(staging_adj.flags.needs_repair_fwd);
}

test "repair debt: repairBudgeted skips removed queue entries and still compacts tombstones" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed, 0, 0);
    _ = try graph.removeNode(removed);

    try graph.graph.repair_fwd.append(graph.graph.allocator, removed.index);

    const compacted = try graph.repairBudgeted(1);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
}

test "repair debt: repairNode canonicalizes single-block grouped adjacency preventively" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 3);

    const b0 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 1);

    const g0 = try graph.allocGroup();
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };

    // Reverse backlink so forward/reverse consistency holds.
    const rb = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, rb, .rev).sources[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, rb, .rev, @intCast(1));
    {
        const d1 = try graph.nodeAt(.{ .index = 1 });
        publish.clearPublishedSides(d1);
        publish.publishedRevSide(d1).first_block = rb;
        publish.publishedRevSide(d1).block_count = 1;
        publish.setPublishedRevDegree(d1, @as(u22, @intCast(1)));
        try publish.syncToPublished(&graph, 1);
    }

    const node = try graph.nodeAt(.{ .index = 0 });
    publish.clearPublishedSides(node);
    publish.publishedFwdSide(node).first_block = b0;
    publish.publishedFwdSide(node).block_count = 1;
    publish.publishedFwdSide(node).group_count = 1;
    publish.publishedFwdSide(node).first_group = g0;
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(1)));
    publish.setPublishedFlags(node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, 0);
    graph.graph.edge_count.store(1, .release);

    const summary = try graph.repairNode(.{ .index = 0 });
    try testing.expect(summary.repaired_fwd);
    try graph.validate();

    const repaired = try graph.publishedNodeAdj(.{ .index = 0 });
    try testing.expectEqual(@as(u16, 0), repaired.group_count_fwd);
    try testing.expectEqual(@as(u32, 1), repaired.block_count_fwd);
    try testing.expect(!repaired.flags.removed);
}

test "repair debt: flushRepairs does not discover unflagged tombstone debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    _ = try graph.removeNode(target);
    try graph.validate();

    // After removeNode, source.needs_repair_fwd MUST be true (tombstone debt).
    {
        const adj = try graph.publishedNodeAdj(source);
        try testing.expect(adj.flags.needs_repair_fwd);
    }

    // Clear needs_repair_fwd and all repair-debt sources. flushRepairs should
    // drain only explicit debt, so the tombstone must remain untouched.
    {
        var meta = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
        var flags = meta.flags();
        flags.needs_repair_fwd = false;
        meta = meta.withFlags(flags);
        publish.storePublishedMeta(&graph, source.index, meta);
    }

    // Drain best-effort queues.
    graph.graph.repair_fwd.clearRetainingCapacity();
    graph.graph.repair_rev.clearRetainingCapacity();

    // Reset scan cursors so the flag-scan pass starts from the beginning.
    graph.graph.repair_scan_cursor_fwd = 0;
    graph.graph.repair_scan_cursor_rev = 0;
    graph.graph.repair_scan_cursor_tombstone = 0;

    // flushRepairs should not discover or compact unflagged debt.
    const flush = try graph.flushRepairs();
    try testing.expectEqual(@as(usize, 0), flush.repaired_nodes);

    const after = try graph.publishedNodeAdj(source);
    try testing.expect(!after.flags.needs_repair_fwd);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "repair debt: valid two-run grouped forward adjacency does not set spurious needs_repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodesForTest(&graph, 258);
    const node = graph_mod.NodeId{ .index = 0 };

    // Group 0: 4 contiguous full blocks (all at or above MIN_OCCUPANCY).
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 64);
    fillBlock(&graph, b1, 65, 64);
    fillBlock(&graph, b2, 129, 64);
    fillBlock(&graph, b3, 193, 64);

    // Block at the next index is allocated but not owned by any node,
    // creating a physical gap so the two groups are non-contiguous and
    // a grouped-but-contiguous canonicalization is not required.
    _ = try graph.allocBlockFwd();

    // Group 1: single tail block.
    const b5 = try graph.allocBlockFwd();
    fillBlock(&graph, b5, 257, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 4 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b5, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = b0;
    publish.publishedFwdSide(node_buffer).block_count = 5;
    publish.publishedFwdSide(node_buffer).group_count = 2;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(257)));

    var staging_adj = node_buffer.publishedAdj();
    graph_mod.repair_mod.updateRepairDebt(&graph.graph, &staging_adj, node.index, .fwd);

    // This is a healthy grouped adjacency: 4 full blocks in the
    // first run (≥4 blocks, no under-full non-tail), 1 tail block
    // in the second run, groups are non-contiguous, no tombstones.
    // needs_repair_fwd must NOT be set.
    try testing.expect(!staging_adj.flags.needs_repair_fwd);
}

test "repair debt: globally sorted bit gates conclusive lookup" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..130) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, 0);
    }

    // Ascending hot-path appends preserve the sorted bit; an out-of-order
    // insert (a destination below every prior one) clears it conservatively.
    const ascending_published = page_ops.nodePublishedAtConst(&graph.graph, source);
    const ascending_meta = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
    try testing.expect(ascending_published.publishedFwdSortedFromMeta(ascending_meta));

    try graph.addEdge(source, .{ .index = 0 }, 0, 0);
    const node_published_before = page_ops.nodePublishedAtConst(&graph.graph, source);
    const meta_before = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
    try testing.expect(!node_published_before.publishedFwdSortedFromMeta(meta_before));

    // Explicit repair rebuilds sorted and publishes the bit.
    _ = try graph.repairNode(source);
    const node_published_after = page_ops.nodePublishedAtConst(&graph.graph, source);
    const meta_after = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
    try testing.expect(node_published_after.publishedFwdSortedFromMeta(meta_after));

    // Lookups still behave identically: hits found, misses conclusive.
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, .{ .index = 5 }, 0, 0));
    try graph.validate();
}
