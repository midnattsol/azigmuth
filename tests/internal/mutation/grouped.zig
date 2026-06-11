const std = @import("std");
const neighbors = @import("neighbors");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn setForwardBlock(graph: *graph_mod.Graph, block_index: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |edge_index| {
        block.destinations[edge_index] = first_destination + @as(u32, @intCast(edge_index));
        block.relations[edge_index] = 0;
        block.flags[edge_index] = 0;
    }
    page_ops.setBlockLiveCount(&graph.graph, block_index, .fwd, @intCast(count));
}

fn setReverseBlock(graph: *graph_mod.Graph, block_index: u32, first_source: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    for (0..count) |source_index| {
        block.sources[source_index] = first_source + @as(u32, @intCast(source_index));
    }
    page_ops.setBlockLiveCount(&graph.graph, block_index, .rev, @intCast(count));
}

fn publishForwardGroups(graph: *graph_mod.Graph, node: graph_mod.NodeId, groups: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    publish.publishedFwdSide(node_buffer).group_count = @intCast(groups.len);
    publish.publishedFwdSide(node_buffer).first_group = groups[0];
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    var total: usize = 0;
    for (groups) |group_index| {
        const group = page_ops.groupAtConst(&graph.graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += page_ops.blockLiveCount(&graph.graph, @intCast(block_index), .fwd);
        }
    }
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn publishReverseGroups(graph: *graph_mod.Graph, node: graph_mod.NodeId, groups: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedRevSide(node_buffer).block_count = block_count;
    publish.publishedRevSide(node_buffer).group_count = @intCast(groups.len);
    publish.publishedRevSide(node_buffer).first_group = groups[0];
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    var total: usize = 0;
    for (groups) |group_index| {
        const group = page_ops.groupAtConst(&graph.graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += page_ops.blockLiveCount(&graph.graph, @intCast(block_index), .rev);
        }
    }
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination: graph_mod.NodeId, source_index: u32) !void {
    const block = try graph.allocBlockRev();
    var reverse_block = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    reverse_block.sources[0] = source_index;
    page_ops.setBlockLiveCount(&graph.graph, block, .rev, 1);

    const node_buffer = try graph.nodeAt(destination);
    publish.publishedRevSide(node_buffer).first_block = block;
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, destination.index);
}

fn publishSingleForwardEdge(graph: *graph_mod.Graph, source: graph_mod.NodeId, destination_index: u32) !void {
    const block = try graph.allocBlockFwd();
    var forward_block = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    forward_block.destinations[0] = destination_index;
    forward_block.relations[0] = 0;
    forward_block.flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, block, .fwd, 1);

    const node_buffer = try graph.nodeAt(source);
    publish.publishedFwdSide(node_buffer).first_block = block;
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, source.index);
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
    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block1, .count = 1 };
    page_ops.groupAt(&graph.graph, group2).* = .{ .start = block2, .count = 1 };
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
    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block1, .count = 1 };
    page_ops.groupAt(&graph.graph, group2).* = .{ .start = block2, .count = 1 };
    try publishReverseGroups(graph, destination, &[_]u32{ group0, group1, group2 }, 3);

    for (1..100) |source_index| {
        try publishSingleForwardEdge(graph, .{ .index = @intCast(source_index) }, destination.index);
    }
    graph.graph.edge_count.store(99, .release);
    return destination;
}

test "mutation grouped: non-tail and tail removes succeed while occupancy holds" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildGroupedForwardGraph(&graph);
    // Non-tail blocks hold 49 live edges: one removal keeps them at the hard
    // occupancy bound, so the structural rebuild path completes the removal.
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

test "mutation grouped: non-tail and tail reverse removes succeed while occupancy holds" {
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
    page_ops.setBlockLiveCount(&graph.graph, first_block_index, .fwd, @intCast(48));
    publish.setPublishedFwdDegree(try graph.nodeAt(source), 98);
    const reverse_node = try graph.nodeAt(.{ .index = 49 });
    // Retire reverse block before clearing it to avoid orphan detection.
    const rev_block = publish.publishedRevSide(reverse_node).first_block;
    page_ops.freeBlock(&graph.graph, rev_block, .rev);
    publish.publishedRevSide(reverse_node).block_count = 0;
    publish.publishedRevSide(reverse_node).first_block = 0;
    publish.setPublishedRevDegree(reverse_node, @as(u22, @intCast(0)));
    try publish.syncToPublished(&graph, source.index);
    try publish.syncToPublished(&graph, 49);
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
    page_ops.setBlockLiveCount(&graph.graph, first_block_index, .rev, @intCast(48));
    publish.setPublishedRevDegree(try graph.nodeAt(destination), 98);
    const forward_node = try graph.nodeAt(.{ .index = 49 });
    // Retire forward block before clearing it to avoid orphan detection.
    const fwd_block = publish.publishedFwdSide(forward_node).first_block;
    page_ops.freeBlock(&graph.graph, fwd_block, .fwd);
    publish.publishedFwdSide(forward_node).block_count = 0;
    publish.publishedFwdSide(forward_node).first_block = 0;
    publish.setPublishedFwdDegree(forward_node, @as(u22, @intCast(0)));
    try publish.syncToPublished(&graph, destination.index);
    try publish.syncToPublished(&graph, 49);
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
    const second_group = first_group + 1;
    const tail_group = second_group + 1;
    const tail_before = page_ops.groupAtConst(&graph.graph, tail_group).*;

    const new_destination = try graph.addNode();
    try graph.addEdge(source, new_destination, 0, 0);

    const tail_after = page_ops.groupAtConst(&graph.graph, tail_group).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expect((try graph.publishedNodeAdj(source)).first_group_fwd != first_group);
    try graph.validate();
}

test "mutation grouped: addEdge clones reverse group chain before tail mutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildGroupedReverseGraph(&graph);
    const before_adj = try graph.publishedNodeAdj(destination);
    const first_group = before_adj.first_group_rev;
    const second_group = first_group + 1;
    const tail_group = second_group + 1;
    const tail_before = page_ops.groupAtConst(&graph.graph, tail_group).*;

    const new_source = try graph.addNode();
    try graph.addEdge(new_source, destination, 0, 0);

    const tail_after = page_ops.groupAtConst(&graph.graph, tail_group).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expect((try graph.publishedNodeAdj(destination)).first_group_rev != first_group);
    try graph.validate();
}

test "mutation grouped: removeEdge tail block clones chain without mutating published groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildGroupedForwardGraph(&graph);
    const before = try graph.publishedNodeAdj(source);
    const first_group = before.first_group_fwd;
    const second_group = first_group + 1;
    const tail_group = second_group + 1;
    const tail_before = page_ops.groupAtConst(&graph.graph, tail_group).*;

    try testing.expect(try graph.removeEdge(source, .{ .index = 99 }));

    const tail_after_old = page_ops.groupAtConst(&graph.graph, tail_group).*;
    try testing.expectEqual(tail_before.start, tail_after_old.start);
    try testing.expectEqual(tail_before.count, tail_after_old.count);

    const after = try graph.publishedNodeAdj(source);
    try testing.expect(after.first_group_fwd != first_group);
    try testing.expectEqual(before.group_count_fwd - 1, after.group_count_fwd);
    try testing.expectEqual(before.block_count_fwd - 1, after.block_count_fwd);
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
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1 };

    const node_buffer = try graph.nodeAt(source);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.publishedFwdSide(node_buffer).group_count = 1;
    publish.publishedFwdSide(node_buffer).first_group = group;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(graph, source.index);
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
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1 };

    const node_buffer = try graph.nodeAt(destination);
    publish.clearPublishedSides(node_buffer);
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.publishedRevSide(node_buffer).group_count = 1;
    publish.publishedRevSide(node_buffer).first_group = group;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    try publish.syncToPublished(graph, destination.index);
    return .{ .block = block, .group = group };
}

test "mutation grouped: addEdge COW on single-block grouped forward updates group.start" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 4);
    const source = graph_mod.NodeId{ .index = 0 };
    const old_dest = graph_mod.NodeId{ .index = 1 };
    const new_dest = graph_mod.NodeId{ .index = 2 };

    _ = try publishSingleBlockGroupedForward(&graph, source, old_dest.index);

    // Reverse backlink for old_dest (ungrouped, contiguous)
    try publishSingleReverseSource(&graph, old_dest, source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(source, new_dest, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(source));

    const after = graph.nodeRefAny(source).publishedAdj();
    try testing.expectEqual(@as(u16, 0), after.group_count_fwd);
    try testing.expectEqual(@as(u16, 1), after.block_count_fwd);
    try neighbors.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{ old_dest.index, new_dest.index });
}

test "mutation grouped: removeEdge repacks in-call when COW split exceeds MAX_GROUPS_PER_NODE" {
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
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 3 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b6, .count = 1 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b8, .count = 1 };

    try publishForwardGroups(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 6);

    // Reverse backlinks for destinations 1..242
    for (1..243) |destination_index| {
        try publishSingleReverseSource(&graph, .{ .index = @intCast(destination_index) }, source.index);
    }
    graph.graph.edge_count.store(242, .release);

    // Block 3 has 49 edges. Removing one from a non-tail middle block
    // forces a COW replacement. The new block lands at index 1 (LIFO from
    // the free stack), which would break contiguity of the [2..4] run and
    // push the side past MAX_GROUPS_PER_NODE. The removal performs the
    // synchronous in-call dense repack and succeeds
    // instead of bouncing RepairRequired to the caller.
    try testing.expect(try graph.removeEdge(source, .{ .index = 97 }));

    try graph.validate();
    try testing.expectEqual(@as(u64, 241), graph.edgeCount());
    try testing.expectEqual(@as(usize, 241), try graph.outDegree(source));

    // The repacked side satisfies the run bound again.
    const adjacency_after = try graph.publishedNodeAdj(source);
    try testing.expect(adjacency_after.group_count_fwd <= 4);
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
    _ = try publishSingleBlockGroupedReverse(&graph, dest, old_source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(new_source, dest, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(dest));

    const after = try graph.publishedNodeAdj(dest);
    try testing.expectEqual(@as(u16, 0), after.group_count_rev);
    try testing.expectEqual(@as(u16, 1), after.block_count_rev);
    try neighbors.expectInNeighbors(&graph, testing.allocator, dest, &[_]u32{ old_source.index, new_source.index });
}

test "mutation grouped: addEdge appends past four runs without structural rebuild" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 258);
    const source = graph_mod.NodeId{ .index = 0 };

    const b0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const b6 = try graph.allocBlockFwd();
    const spare7 = try graph.allocBlockFwd();

    setForwardBlock(&graph, b0, 1, 64);
    setForwardBlock(&graph, b2, 65, 64);
    setForwardBlock(&graph, b4, 129, 64);
    setForwardBlock(&graph, b6, 193, 64);

    page_ops.freeBlock(&graph.graph, spare7, .fwd);
    page_ops.freeBlock(&graph.graph, 5, .fwd);
    page_ops.freeBlock(&graph.graph, 3, .fwd);
    page_ops.freeBlock(&graph.graph, 1, .fwd);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    const g3 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b6, .count = 1 };
    try publishForwardGroups(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 4);

    for (1..257) |destination_idx| {
        try publishSingleReverseSource(&graph, .{ .index = @intCast(destination_idx) }, source.index);
    }
    graph.graph.edge_count.store(256, .release);
    try graph.validate();

    try graph.addEdge(source, .{ .index = 257 }, 0, 0);
    try graph.validate();

    const after = try graph.publishedNodeAdj(source);
    try testing.expectEqual(@as(usize, 257), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 257), graph.edgeCount());
    try testing.expect(after.group_count_fwd <= constants.MAX_GROUPS_PER_NODE);
    try testing.expectEqual(@as(u16, 5), after.block_count_fwd);
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(.{ .index = 257 }));
}

test "mutation grouped: addEdge replaces partial tail within four-run limit" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 259);
    const source = graph_mod.NodeId{ .index = 0 };

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();

    setForwardBlock(&graph, b0, 1, 64);
    setForwardBlock(&graph, b1, 65, 64);
    setForwardBlock(&graph, b2, 129, 64);
    setForwardBlock(&graph, b3, 193, 64);
    setForwardBlock(&graph, b4, 257, 1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    const g3 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b3, .count = 2 };
    try publishForwardGroups(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 5);

    for (1..258) |destination_idx| {
        try publishSingleReverseSource(&graph, .{ .index = @intCast(destination_idx) }, source.index);
    }
    graph.graph.edge_count.store(257, .release);
    try graph.validate();

    try graph.addEdge(source, .{ .index = 258 }, 0, 0);
    try graph.validate();

    const after = try graph.publishedNodeAdj(source);
    try testing.expectEqual(@as(usize, 258), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 258), graph.edgeCount());
    try testing.expectEqual(@as(u16, 3), after.group_count_fwd);
    try testing.expectEqual(@as(u16, 5), after.block_count_fwd);
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(.{ .index = 258 }));
}
