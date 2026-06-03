const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;
const helpers = @import("helpers.zig");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn setForwardBlock(graph: *graph_mod.Graph, block_index: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |edge_index| {
        block.edges[edge_index] = .{ .destination = first_destination + @as(u32, @intCast(edge_index)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
}

fn setReverseBlock(graph: *graph_mod.Graph, block_index: u32, first_source: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    for (0..count) |source_index| {
        block.sources[source_index] = first_source + @as(u32, @intCast(source_index));
    }
    block.mask = constants.denseMask(count);
}

fn publishForwardGroups(graph: *graph_mod.Graph, node: graph_mod.NodeId, groups: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = block_count;
    helpers.publishedFwdSide(node_buffer).group_count = @intCast(groups.len);
    helpers.publishedFwdSide(node_buffer).first_group = groups[0];
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    var total: usize = 0;
    for (groups) |group_index| {
        const group = page_ops.groupAtConst(&graph.graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += @popCount(page_ops.edgeBlockAtConst(&graph.graph, @intCast(block_index), .fwd).mask);
        }
    }
    helpers.setPublishedFwdDegree(node_buffer, @as(u22, @intCast((total))));
}

fn publishReverseGroups(graph: *graph_mod.Graph, node: graph_mod.NodeId, groups: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedRevSide(node_buffer).block_count = block_count;
    helpers.publishedRevSide(node_buffer).group_count = @intCast(groups.len);
    helpers.publishedRevSide(node_buffer).first_group = groups[0];
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    var total: usize = 0;
    for (groups) |group_index| {
        const group = page_ops.groupAtConst(&graph.graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += @popCount(page_ops.edgeBlockAtConst(&graph.graph, @intCast(block_index), .rev).mask);
        }
    }
    helpers.setPublishedRevDegree(node_buffer, @as(u22, @intCast((total))));
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination: graph_mod.NodeId, source_index: u32) !void {
    const block = try graph.allocBlockRev();
    var reverse_block = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    reverse_block.sources[0] = source_index;
    reverse_block.mask = constants.denseMask(1);

    const node_buffer = try graph.nodeAt(destination);
    helpers.publishedRevSide(node_buffer).first_block = block;
    helpers.publishedRevSide(node_buffer).block_count = 1;
    helpers.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
}

fn publishSingleForwardEdge(graph: *graph_mod.Graph, source: graph_mod.NodeId, destination_index: u32) !void {
    const block = try graph.allocBlockFwd();
    var forward_block = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    forward_block.edges[0] = .{ .destination = destination_index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    forward_block.mask = constants.denseMask(1);

    const node_buffer = try graph.nodeAt(source);
    helpers.publishedFwdSide(node_buffer).first_block = block;
    helpers.publishedFwdSide(node_buffer).block_count = 1;
    helpers.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
}

fn buildGroupedForwardGraph(graph: *graph_mod.Graph) !graph_mod.NodeId {
    try addNodeCount(graph, 100);
    const source = graph_mod.NodeId{ .index = 0 };

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    const block2 = try graph.allocBlockFwd();
    setForwardBlock(graph, block0, 1, 49);
    setForwardBlock(graph, block1, 50, 49);
    setForwardBlock(graph, block2, 99, 1);

    const group0 = try graph.allocGroup();
    const group1 = try graph.allocGroup();
    const group2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 1, .next = group1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block1, .count = 1, .next = group2 };
    page_ops.groupAt(&graph.graph, group2).* = .{ .start = block2, .count = 1, .next = constants.END_OF_CHAIN };
    try publishForwardGroups(graph, source, &[_]u32{ group0, group1, group2 }, 3);

    for (1..100) |destination_index| {
        try publishSingleReverseSource(graph, .{ .index = @intCast(destination_index) }, source.index);
    }
    graph.graph.edge_count.store(99, .release);
    return source;
}

fn buildGroupedReverseGraph(graph: *graph_mod.Graph) !graph_mod.NodeId {
    try addNodeCount(graph, 100);
    const destination = graph_mod.NodeId{ .index = 0 };

    const block0 = try graph.allocBlockRev();
    const block1 = try graph.allocBlockRev();
    const block2 = try graph.allocBlockRev();
    setReverseBlock(graph, block0, 1, 49);
    setReverseBlock(graph, block1, 50, 49);
    setReverseBlock(graph, block2, 99, 1);

    const group0 = try graph.allocGroup();
    const group1 = try graph.allocGroup();
    const group2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 1, .next = group1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block1, .count = 1, .next = group2 };
    page_ops.groupAt(&graph.graph, group2).* = .{ .start = block2, .count = 1, .next = constants.END_OF_CHAIN };
    try publishReverseGroups(graph, destination, &[_]u32{ group0, group1, group2 }, 3);

    for (1..100) |source_index| {
        try publishSingleForwardEdge(graph, .{ .index = @intCast(source_index) }, destination.index);
    }
    graph.graph.edge_count.store(99, .release);
    return destination;
}

test "mutation grouped: remove from first, middle, and tail forward groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildGroupedForwardGraph(&graph);
    try testing.expect(try graph.removeEdge(source, .{ .index = 1 }));
    try testing.expect(try graph.removeEdge(source, .{ .index = 50 }));
    try testing.expect(try graph.removeEdge(source, .{ .index = 99 }));

    try testing.expectEqual(@as(u64, 96), graph.edgeCount());
    try testing.expectEqual(@as(usize, 96), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(.{ .index = 1 }));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(.{ .index = 50 }));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(.{ .index = 99 }));
    try graph.validate();
}

test "mutation grouped: remove from first, middle, and tail reverse groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildGroupedReverseGraph(&graph);
    try testing.expect(try graph.removeEdge(.{ .index = 1 }, destination));
    try testing.expect(try graph.removeEdge(.{ .index = 50 }, destination));
    try testing.expect(try graph.removeEdge(.{ .index = 99 }, destination));

    try testing.expectEqual(@as(u64, 96), graph.edgeCount());
    try testing.expectEqual(@as(usize, 96), try graph.inDegree(destination));
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(.{ .index = 1 }));
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(.{ .index = 50 }));
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(.{ .index = 99 }));
    try graph.validate();
}

test "mutation grouped: RepairRequired in grouped forward does not publish" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildGroupedForwardGraph(&graph);
    for (1..2) |_| {}
    const first_block_index = page_ops.groupAtConst(&graph.graph, (try graph.publishedNodeAdj(source)).first_group_fwd).start;
    page_ops.edgeBlockAt(&graph.graph, first_block_index, .fwd).mask = constants.denseMask(48);
    helpers.setPublishedFwdDegree(try graph.nodeAt(source), 98);
    const reverse_node = try graph.nodeAt(.{ .index = 49 });
    // Retire reverse block before clearing it to avoid orphan detection.
    const rev_block = helpers.publishedRevSide(reverse_node).first_block;
    page_ops.freeBlock(&graph.graph, rev_block, .rev);
    helpers.publishedRevSide(reverse_node).block_count = 0;
    helpers.publishedRevSide(reverse_node).first_block = 0;
    helpers.setPublishedRevDegree(reverse_node, @as(u22, @intCast(0)));
    graph.graph.edge_count.store(98, .release);

    try testing.expectError(error.RepairRequired, graph.removeEdge(source, .{ .index = 1 }));
    try testing.expectEqual(@as(u64, 98), graph.edgeCount());
    try graph.validate();
}

test "mutation grouped: RepairRequired in grouped reverse does not publish" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildGroupedReverseGraph(&graph);
    const first_block_index = page_ops.groupAtConst(&graph.graph, (try graph.publishedNodeAdj(destination)).first_group_rev).start;
    page_ops.edgeBlockAt(&graph.graph, first_block_index, .rev).mask = constants.denseMask(48);
    helpers.setPublishedRevDegree(try graph.nodeAt(destination), 98);
    const forward_node = try graph.nodeAt(.{ .index = 49 });
    // Retire forward block before clearing it to avoid orphan detection.
    const fwd_block = helpers.publishedFwdSide(forward_node).first_block;
    page_ops.freeBlock(&graph.graph, fwd_block, .fwd);
    helpers.publishedFwdSide(forward_node).block_count = 0;
    helpers.publishedFwdSide(forward_node).first_block = 0;
    helpers.setPublishedFwdDegree(forward_node, @as(u22, @intCast(0)));
    graph.graph.edge_count.store(98, .release);

    try testing.expectError(error.RepairRequired, graph.removeEdge(.{ .index = 1 }, destination));
    try testing.expectEqual(@as(u64, 98), graph.edgeCount());
    try graph.validate();
}

test "mutation grouped: addEdge clones forward group chain before tail mutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildGroupedForwardGraph(&graph);
    const before_adj = try graph.publishedNodeAdj(source);
    const first_group = before_adj.first_group_fwd;
    const second_group = page_ops.groupAtConst(&graph.graph, first_group).next;
    const tail_group = page_ops.groupAtConst(&graph.graph, second_group).next;
    const tail_before = page_ops.groupAtConst(&graph.graph, tail_group).*;

    const new_destination = try graph.addNode();
    try graph.addEdge(source, new_destination, 0, 0);

    const tail_after = page_ops.groupAtConst(&graph.graph, tail_group).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expectEqual(tail_before.next, tail_after.next);
    try testing.expect((try graph.publishedNodeAdj(source)).first_group_fwd != first_group);
    try graph.validate();
}

test "mutation grouped: addEdge clones reverse group chain before tail mutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildGroupedReverseGraph(&graph);
    const before_adj = try graph.publishedNodeAdj(destination);
    const first_group = before_adj.first_group_rev;
    const second_group = page_ops.groupAtConst(&graph.graph, first_group).next;
    const tail_group = page_ops.groupAtConst(&graph.graph, second_group).next;
    const tail_before = page_ops.groupAtConst(&graph.graph, tail_group).*;

    const new_source = try graph.addNode();
    try graph.addEdge(new_source, destination, 0, 0);

    const tail_after = page_ops.groupAtConst(&graph.graph, tail_group).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expectEqual(tail_before.next, tail_after.next);
    try testing.expect((try graph.publishedNodeAdj(destination)).first_group_rev != first_group);
    try graph.validate();
}

fn publishSingleBlockGroupedForward(
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    destination_index: u32,
) !struct { block: u32, group: u32 } {
    const block = try graph.allocBlockFwd();
    setForwardBlock(graph, block, destination_index, 1);
    const group = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = constants.END_OF_CHAIN };

    const node_buffer = try graph.nodeAt(source);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 1;
    helpers.publishedFwdSide(node_buffer).group_count = 1;
    helpers.publishedFwdSide(node_buffer).first_group = group;
    helpers.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    return .{ .block = block, .group = group };
}

fn publishSingleBlockGroupedReverse(
    graph: *graph_mod.Graph,
    destination: graph_mod.NodeId,
    source_index: u32,
) !struct { block: u32, group: u32 } {
    const block = try graph.allocBlockRev();
    setReverseBlock(graph, block, source_index, 1);
    const group = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = constants.END_OF_CHAIN };

    const node_buffer = try graph.nodeAt(destination);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedRevSide(node_buffer).block_count = 1;
    helpers.publishedRevSide(node_buffer).group_count = 1;
    helpers.publishedRevSide(node_buffer).first_group = group;
    helpers.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    helpers.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    return .{ .block = block, .group = group };
}

test "mutation grouped: addEdge COW on single-block grouped forward updates group.start" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 4);
    const source = graph_mod.NodeId{ .index = 0 };
    const old_dest = graph_mod.NodeId{ .index = 1 };
    const new_dest = graph_mod.NodeId{ .index = 2 };

    const old_fwd = try publishSingleBlockGroupedForward(&graph, source, old_dest.index);

    // Reverse backlink for old_dest (ungrouped, contiguous)
    try publishSingleReverseSource(&graph, old_dest, source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(source, new_dest, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(source));

    const after = (try graph.nodeAtConst(source)).publishedAdj();
    try testing.expectEqual(@as(u16, 1), after.group_count_fwd);
    try testing.expectEqual(@as(u16, 1), after.block_count_fwd);
    const after_group = page_ops.groupAtConst(&graph.graph, after.first_group_fwd);
    try testing.expect(after_group.start != old_fwd.block);
    try helpers.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{ old_dest.index, new_dest.index });
}

test "mutation grouped: removeEdge returns RepairRequired when COW split exceeds MAX_GROUPS_PER_NODE" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 243);
    const source = graph_mod.NodeId{ .index = 0 };

    // Allocate 9 forward blocks: 0..8, then free 7,5,1.
    // Free-stack LIFO order → next allocBlock returns 1.
    const b0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b6 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b8 = try graph.allocBlockFwd();

    page_ops.freeBlock(&graph.graph, 7, .fwd);
    page_ops.freeBlock(&graph.graph, 5, .fwd);
    page_ops.freeBlock(&graph.graph, 1, .fwd);

    // Fill forward blocks. Block 3 has 49 edges, the rest 48 or 1.
    setForwardBlock(&graph, b0, 1, 48);
    setForwardBlock(&graph, b2, 49, 48);
    setForwardBlock(&graph, b3, 97, 49);
    setForwardBlock(&graph, b4, 146, 48);
    setForwardBlock(&graph, b6, 194, 48);
    setForwardBlock(&graph, b8, 242, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    const g3 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 3, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b6, .count = 1, .next = g3 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b8, .count = 1, .next = constants.END_OF_CHAIN };

    try publishForwardGroups(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 6);

    // Reverse backlinks for destinations 1..242
    for (1..243) |destination_index| {
        try publishSingleReverseSource(&graph, .{ .index = @intCast(destination_index) }, source.index);
    }
    graph.graph.edge_count.store(242, .release);

    // Block 3 has 49 edges. Removing one from a non-tail middle block
    // forces a COW replacement. The new block lands at index 1 (LIFO
    // from the free stack), which breaks both physical contiguity
    // of the [2..4] run and creates 6 groups from the original 4.
    try testing.expectError(error.RepairRequired, graph.removeEdge(source, .{ .index = 97 }));

    // Verify that the mutation did not publish partial state.
    try graph.validate();
    try testing.expectEqual(@as(u64, 242), graph.edgeCount());
    try testing.expectEqual(@as(usize, 242), try graph.outDegree(source));
}

test "mutation grouped: addEdge COW on single-block grouped reverse updates group.start" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 4);
    const old_source = graph_mod.NodeId{ .index = 0 };
    const dest = graph_mod.NodeId{ .index = 1 };
    const new_source = graph_mod.NodeId{ .index = 2 };

    // Forward on old_source (ungrouped)
    try publishSingleForwardEdge(&graph, old_source, dest.index);

    // Reverse on dest: single-block grouped
    const old_rev = try publishSingleBlockGroupedReverse(&graph, dest, old_source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(new_source, dest, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(dest));

    const after = (try graph.nodeAtConst(dest)).publishedAdj();
    try testing.expectEqual(@as(u16, 1), after.group_count_rev);
    try testing.expectEqual(@as(u16, 1), after.block_count_rev);
    const after_group = page_ops.groupAtConst(&graph.graph, after.first_group_rev);
    try testing.expect(after_group.start != old_rev.block);
    try helpers.expectInNeighbors(&graph, testing.allocator, dest, &[_]u32{ old_source.index, new_source.index });
}
