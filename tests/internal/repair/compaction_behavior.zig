const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const repair = graph_mod.repair_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn publishForwardBlocks(graph: *graph_mod.Graph, node: graph_mod.NodeId, first_block: u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = first_block;
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    var total: usize = 0;
    for (first_block..first_block + block_count) |block_idx| {
        total += page_ops.blockLiveCount(&graph.graph, @intCast(block_idx), .fwd);
    }
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn publishReverseBlocks(graph: *graph_mod.Graph, node: graph_mod.NodeId, first_block: u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedRevSide(node_buffer).first_block = first_block;
    publish.publishedRevSide(node_buffer).block_count = block_count;
    var total: usize = 0;
    for (first_block..first_block + block_count) |block_idx| {
        total += page_ops.blockLiveCount(&graph.graph, @intCast(block_idx), .rev);
    }
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn fillForwardBlock(graph: *graph_mod.Graph, block_idx: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    for (0..count) |edge_idx| {
        block.destinations[edge_idx] = first_destination + @as(u32, @intCast(edge_idx));
        block.relations[edge_idx] = 0;
        block.flags[edge_idx] = 0;
    }
    page_ops.setBlockLiveCount(&graph.graph, block_idx, .fwd, @intCast(count));
}

fn fillReverseBlock(graph: *graph_mod.Graph, block_idx: u32, first_source: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    for (0..count) |source_idx| {
        block.sources[source_idx] = first_source + @as(u32, @intCast(source_idx));
    }
    page_ops.setBlockLiveCount(&graph.graph, block_idx, .rev, @intCast(count));
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination_idx: u32, source_idx: u32) !void {
    const block_idx = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    block.sources[0] = source_idx;
    page_ops.setBlockLiveCount(&graph.graph, block_idx, .rev, @intCast(1));

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

test "repair: merges two underfull forward blocks into one block" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 50);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_block, 1, 20);
    fillForwardBlock(&graph, second_block, 21, 20);
    try publishForwardBlocks(&graph, .{ .index = 0 }, first_block, 2);
    try publishReverseSourcesForForwardRange(&graph, 0, 1, 20);
    try publishReverseSourcesForForwardRange(&graph, 0, 21, 20);
    graph.graph.edge_count.store(40, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, .{ .index = 0 }, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);
    try testing.expectEqual(@as(usize, 40), try graph.outDegree(.{ .index = 0 }));
    try testing.expectEqual(@as(u16, 1), (try graph.publishedNodeAdj(.{ .index = 0 })).block_count_fwd);
        try graph.validate();
}

test "repair: fill-and-shift keeps two blocks when merged total exceeds capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 90);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_block, 1, 47);
    fillForwardBlock(&graph, second_block, 48, 36);
    try publishForwardBlocks(&graph, .{ .index = 0 }, first_block, 2);
    try publishReverseSourcesForForwardRange(&graph, 0, 1, 47);
    try publishReverseSourcesForForwardRange(&graph, 0, 48, 36);
    graph.graph.edge_count.store(83, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, .{ .index = 0 }, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(.{ .index = 0 }));

    const adjacency = try graph.publishedNodeAdj(.{ .index = 0 });
    try testing.expectEqual(@as(u16, 2), adjacency.block_count_fwd);
    try testing.expectEqual(@as(u7, 64), page_ops.blockLiveCount(&graph.graph, adjacency.first_block_fwd, .fwd));
    try graph.validate();
}

test "repair: reverse adjacency can be compacted independently" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 50);
    const destination = graph_mod.NodeId{ .index = 49 };
    const first_block = try graph.allocBlockRev();
    const second_block = try graph.allocBlockRev();
    fillReverseBlock(&graph, first_block, 0, 20);
    fillReverseBlock(&graph, second_block, 20, 20);
    try publishReverseBlocks(&graph, destination, first_block, 2);

    const compacted = try repair.repairNodeSide(&graph.graph, destination, .rev);
    try testing.expectEqual(@as(usize, 1), compacted);
    try testing.expectEqual(@as(usize, 40), try graph.inDegree(destination));
    try testing.expectEqual(@as(u16, 1), (try graph.publishedNodeAdj(destination)).block_count_rev);
}

test "repair: repairNode consolidates a fragmented reverse adjacency into a valid layout" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const source_count: usize = 80;
    var sources: [source_count]graph_mod.NodeId = undefined;
    for (0..source_count) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], target, 0, 0);
    }

    const remove_indices = [_]usize{ 79, 78, 77, 76, 75, 74, 73, 72, 71, 70 };
    for (remove_indices) |remove_idx| {
        _ = try graph.removeEdge(sources[remove_idx], target);
    }

    const before_repair_adj = try graph.publishedNodeAdj(target);
    try testing.expect(before_repair_adj.group_count_rev > 0 or before_repair_adj.block_count_rev > 1);

    _ = try graph.repairNode(target);

    const after_repair_adj = try graph.publishedNodeAdj(target);
    try testing.expectEqual(@as(usize, source_count - remove_indices.len), try graph.inDegree(target));
    try testing.expect(after_repair_adj.block_count_rev >= 1);

    var snapshot = try graph.inNeighbors(target);
    const neighbor_list = try graph_mod.materializeConsuming(&snapshot, allocator);
    defer allocator.free(neighbor_list);
    try testing.expectEqual(@as(usize, source_count - remove_indices.len), neighbor_list.len);
    for (neighbor_list) |neighbor| {
        try testing.expect(graph.hasNode(neighbor));
    }

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "repair: repairNode compacts under-full adjacent blocks" {
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
    page_ops.setBlockLiveCount(&graph.graph, block0, .fwd, @intCast(47));

    for (0..36) |edge_idx| {
        second_block_edges.destinations[edge_idx] = @intCast(edge_idx + 48);
        second_block_edges.relations[edge_idx] = 0;
        second_block_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockLiveCount(&graph.graph, block1, .fwd, @intCast(36));

    const node = try graph.nodeAt(source);
    publish.clearPublishedSides(node);
    publish.publishedFwdSide(node).first_block = block0;
    publish.publishedFwdSide(node).block_count = 2;
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(83)));
    try publish.syncToPublished(&graph, source.index);
    try publishReverseSourcesForForwardRange(&graph, source.index, 1, 47);
    try publishReverseSourcesForForwardRange(&graph, source.index, 48, 36);
    graph.graph.edge_count.store(83, .release);

    _ = try graph.repairNode(source);

    try graph.validate();
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(source));

    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, 83), slice.len);
    for (1..slice.len) |edge_idx| {
        try testing.expect(slice[edge_idx - 1].index < slice[edge_idx].index);
    }
}

test "repair: no-op when every non-tail block meets occupancy" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 80);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_block, 1, 64);
    fillForwardBlock(&graph, second_block, 65, 1);
    try publishForwardBlocks(&graph, .{ .index = 0 }, first_block, 2);
    graph.graph.edge_count.store(65, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, .{ .index = 0 }, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted);
    try testing.expectEqual(@as(u16, 2), (try graph.publishedNodeAdj(.{ .index = 0 })).block_count_fwd);
}

test "repair: repairBudgeted processes at most the requested work" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 90);
    const first_node = graph_mod.NodeId{ .index = 0 };
    const second_node = graph_mod.NodeId{ .index = 1 };

    const first_node_block0 = try graph.allocBlockFwd();
    const first_node_block1 = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_node_block0, 2, 20);
    fillForwardBlock(&graph, first_node_block1, 22, 20);
    try publishForwardBlocks(&graph, first_node, first_node_block0, 2);

    const second_node_block0 = try graph.allocBlockFwd();
    const second_node_block1 = try graph.allocBlockFwd();
    fillForwardBlock(&graph, second_node_block0, 42, 20);
    fillForwardBlock(&graph, second_node_block1, 62, 20);
    try publishForwardBlocks(&graph, second_node, second_node_block0, 2);

    try graph.graph.repair_fwd.append(graph.graph.allocator, first_node.index);
    try graph.graph.repair_fwd.append(graph.graph.allocator, second_node.index);

    const compacted = try repair.repairBudgeted(&graph.graph, 1);
    try testing.expectEqual(@as(usize, 1), compacted);
    try testing.expectEqual(@as(usize, 1), graph.graph.repair_fwd.items.len);
}

test "repair: repairBudgeted counts a node with forward and reverse debt once" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 90);
    const node = graph_mod.NodeId{ .index = 0 };

    const fwd0 = try graph.allocBlockFwd();
    const fwd1 = try graph.allocBlockFwd();
    fillForwardBlock(&graph, fwd0, 1, 20);
    fillForwardBlock(&graph, fwd1, 21, 20);

    const rev0 = try graph.allocBlockRev();
    const rev1 = try graph.allocBlockRev();
    fillReverseBlock(&graph, rev0, 40, 20);
    fillReverseBlock(&graph, rev1, 60, 20);

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = fwd0;
    publish.publishedFwdSide(node_buffer).block_count = 2;
    publish.publishedRevSide(node_buffer).first_block = rev0;
    publish.publishedRevSide(node_buffer).block_count = 2;
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = true, .removed = false });
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(40)));
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(40)));
    try publish.syncToPublished(&graph, node.index);

    try graph.graph.repair_fwd.append(graph.graph.allocator, node.index);
    try graph.graph.repair_rev.append(graph.graph.allocator, node.index);

    const compacted = try repair.repairBudgeted(&graph.graph, 1);
    try testing.expectEqual(@as(usize, 1), compacted);
    const repaired = try graph.publishedNodeAdj(node);
    try testing.expect(!repaired.flags.needs_repair_fwd);
    try testing.expect(!repaired.flags.needs_repair_rev);
}

test "repair: updateRepairDebt does not enqueue duplicates" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 50);
    const node = graph_mod.NodeId{ .index = 0 };
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_block, 1, 20);
    fillForwardBlock(&graph, second_block, 21, 20);
    try publishForwardBlocks(&graph, node, first_block, 2);

    const node_buffer = try graph.nodeAt(node);
    var adj = node_buffer.publishedAdj();
    repair.updateRepairDebt(&graph.graph, &adj, node.index, .fwd);
    publish.setPublishedAdjSnapshot(node_buffer, adj);
    adj = node_buffer.publishedAdj();
    repair.updateRepairDebt(&graph.graph, &adj, node.index, .fwd);
    publish.setPublishedAdjSnapshot(node_buffer, adj);

    try testing.expectEqual(@as(usize, 1), graph.graph.repair_fwd.items.len);
}

test "repair: grouped adjacency can compact across group boundary" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 50);
    const node = graph_mod.NodeId{ .index = 0 };
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    const first_group = try graph.allocGroup();
    const second_group = try graph.allocGroup();

    fillForwardBlock(&graph, first_block, 1, 20);
    fillForwardBlock(&graph, second_block, 21, 20);
    try publishReverseSourcesForForwardRange(&graph, node.index, 1, 20);
    try publishReverseSourcesForForwardRange(&graph, node.index, 21, 20);
    page_ops.edgeBlockGroupAt(&graph.graph, first_group).* = .{ .start = first_block, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, second_group).* = .{ .start = second_block, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 2;
    publish.publishedFwdSide(node_buffer).group_count = 2;
    publish.publishedFwdSide(node_buffer).first_group = first_group;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(40)));
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(40, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);
    try testing.expectEqual(@as(usize, 40), try graph.outDegree(node));
    try graph.validate();
}

// ── Capa 2: Repair ────────────────────────────────────────────────────

test "repair: max_compactions zero does nothing" {
    // repairNodeSide always compacts.  Use repairBudgeted with 0 to
    // test the zero-budget path.
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const compacted = try repair.repairBudgeted(&graph.graph, 0);
    try testing.expectEqual(@as(usize, 0), compacted);
}

test "repair: single block node returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 65);
    const block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, block, 1, 64);
    try publishForwardBlocks(&graph, .{ .index = 0 }, block, 1);

    const compacted = try repair.repairNodeSide(&graph.graph, .{ .index = 0 }, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted);
}

test "repair: already meets occupancy returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 80);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(&graph, first_block, 1, 64);
    fillForwardBlock(&graph, second_block, 65, 1);
    try publishForwardBlocks(&graph, .{ .index = 0 }, first_block, 2);

    const compacted = try repair.repairNodeSide(&graph.graph, .{ .index = 0 }, .fwd);
    try testing.expectEqual(@as(usize, 0), compacted);
    try testing.expectEqual(@as(u16, 2), (try graph.publishedNodeAdj(.{ .index = 0 })).block_count_fwd);
}

test "repair: grouped adjacency becomes contiguous after repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 90);
    const node = graph_mod.NodeId{ .index = 0 };
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    fillForwardBlock(&graph, b0, 1, 20);
    fillForwardBlock(&graph, b1, 21, 20);
    fillForwardBlock(&graph, b2, 41, 20);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = b0;
    publish.publishedFwdSide(node_buffer).block_count = 3;
    publish.publishedFwdSide(node_buffer).group_count = 3;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(60)));
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(60, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);

    const adj = try graph.publishedNodeAdj(node);
    try testing.expectEqual(@as(u16, 0), adj.group_count_fwd);
    try testing.expectEqual(@as(u16, 1), adj.block_count_fwd);
    try testing.expectEqual(@as(usize, 60), try graph.outDegree(node));
}

test "repair: valid forward blocks produce valid reverse after repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 90);
    const src = graph_mod.NodeId{ .index = 0 };
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    fillForwardBlock(&graph, b0, 1, 40);
    fillForwardBlock(&graph, b1, 41, 20);

    // Set up matching reverse edges for each destination
    for (1..61) |dst| {
        const r = try graph.allocBlockRev();
        var rev = page_ops.edgeBlockAt(&graph.graph, r, .rev);
        rev.sources[0] = src.index;
        page_ops.setBlockLiveCount(&graph.graph, r, .rev, @intCast(1));
        const dn = try graph.nodeAt(.{ .index = @intCast(dst) });
        publish.publishedRevSide(dn).first_block = r;
        publish.publishedRevSide(dn).block_count = 1;
        publish.setPublishedRevDegree(dn, @as(u22, @intCast(1)));
        try publish.syncToPublished(&graph, @intCast(dst));
    }

    try publishForwardBlocks(&graph, src, b0, 2);
    graph.graph.edge_count.store(60, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, src, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
}
