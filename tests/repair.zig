const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const repair = test_internals.repair;
const types = test_internals.types;
const helpers = @import("helpers.zig");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn publishForwardBlocks(graph: *graph_mod.Graph, node: graph_mod.NodeId, first_block: u32, block_count: u16) !void {
    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = first_block;
    helpers.publishedFwdSide(node_buffer).block_count = block_count;
    var total: usize = 0;
    for (first_block..first_block + block_count) |block_index| {
        total += @popCount(page_ops.edgeBlockAtConst(&graph.graph, @intCast(block_index), .fwd).mask);
    }
    node_buffer.degree_fwd = @intCast(total);
}

fn publishReverseBlocks(graph: *graph_mod.Graph, node: graph_mod.NodeId, first_block: u32, block_count: u16) !void {
    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedRevSide(node_buffer).first_block = first_block;
    helpers.publishedRevSide(node_buffer).block_count = block_count;
    var total: usize = 0;
    for (first_block..first_block + block_count) |block_index| {
        total += @popCount(page_ops.edgeBlockAtConst(&graph.graph, @intCast(block_index), .rev).mask);
    }
    node_buffer.degree_rev = @intCast(total);
}

fn fillForwardBlock(graph: *graph_mod.Graph, block_index: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |edge_index| {
        block.edges[edge_index] = .{ .destination = first_destination + @as(u32, @intCast(edge_index)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
}

fn fillReverseBlock(graph: *graph_mod.Graph, block_index: u32, first_source: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    for (0..count) |source_index| {
        block.sources[source_index] = first_source + @as(u32, @intCast(source_index));
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
    try testing.expectEqual(@as(usize, 2), graph.graph.retired_blocks_fwd.items.len);
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
    const first_repaired_block = page_ops.edgeBlockAtConst(&graph.graph, adjacency.first_block_fwd, .fwd);
    try testing.expectEqual(constants.FULL_BLOCK_MASK, first_repaired_block.mask);
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

    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = fwd0;
    helpers.publishedFwdSide(node_buffer).block_count = 2;
    helpers.publishedRevSide(node_buffer).first_block = rev0;
    helpers.publishedRevSide(node_buffer).block_count = 2;
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = true, .removed = false });
    node_buffer.degree_fwd = 40;
    node_buffer.degree_rev = 40;

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

    var node_buffer = try graph.nodeAt(node);
    var adj = node_buffer.publishedAdj();
    repair.updateRepairDebt(&graph.graph, &adj, node.index, .fwd);
    helpers.setPublishedAdjSnapshot(node_buffer, adj);
    adj = node_buffer.publishedAdj();
    repair.updateRepairDebt(&graph.graph, &adj, node.index, .fwd);
    helpers.setPublishedAdjSnapshot(node_buffer, adj);

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
    page_ops.groupAt(&graph.graph, first_group).* = .{ .start = first_block, .count = 1, .next = second_group };
    page_ops.groupAt(&graph.graph, second_group).* = .{ .start = second_block, .count = 1, .next = constants.END_OF_CHAIN };

    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 2;
    helpers.publishedFwdSide(node_buffer).group_count = 2;
    helpers.publishedFwdSide(node_buffer).first_group = first_group;
    node_buffer.degree_fwd = 40;
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
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1, .next = constants.END_OF_CHAIN };

    var node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = b0;
    helpers.publishedFwdSide(node_buffer).block_count = 3;
    helpers.publishedFwdSide(node_buffer).group_count = 3;
    helpers.publishedFwdSide(node_buffer).first_group = g0;
    node_buffer.degree_fwd = 60;
    graph.graph.edge_count.store(60, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, node, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);

    const adj = node_buffer.publishedAdj();
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
        rev.mask = constants.denseMask(1);
        var dn = try graph.nodeAt(.{ .index = @intCast(dst) });
        helpers.publishedRevSide(dn).first_block = r;
        helpers.publishedRevSide(dn).block_count = 1;
        dn.degree_rev = 1;
    }

    try publishForwardBlocks(&graph, src, b0, 2);
    graph.graph.edge_count.store(60, .release);

    const compacted = try repair.repairNodeSide(&graph.graph, src, .fwd);
    try testing.expectEqual(@as(usize, 1), compacted);
    try graph.validate();
}
