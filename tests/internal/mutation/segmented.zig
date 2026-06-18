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

fn setForwardBlock(graph: *graph_mod.Graph, block_idx: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    for (0..count) |edge_idx| {
        block.destinations[edge_idx] = first_destination + @as(u32, @intCast(edge_idx));
        block.relations[edge_idx] = 0;
        block.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .fwd, @intCast(count));
}

fn setReverseBlock(graph: *graph_mod.Graph, block_idx: u32, first_source: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    for (0..count) |source_idx| {
        block.sources[source_idx] = first_source + @as(u32, @intCast(source_idx));
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .rev, @intCast(count));
}

fn publishForwardSegments(graph: *graph_mod.Graph, node: graph_mod.NodeId, segments: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    publish.publishedFwdSide(node_buffer).segment_count = @intCast(segments.len);
    publish.publishedFwdSide(node_buffer).first_segment = segments[0];
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    var total: usize = 0;
    for (segments) |segment_idx| {
        const segment = page_ops.edgeBlockSegmentAtConst(&graph.graph, segment_idx);
        for (segment.start..segment.start + segment.count) |block_idx| {
            total += page_ops.blockAliveCount(&graph.graph, @intCast(block_idx), .fwd);
        }
    }
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn publishReverseSegments(graph: *graph_mod.Graph, node: graph_mod.NodeId, segments: []const u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedRevSide(node_buffer).block_count = block_count;
    publish.publishedRevSide(node_buffer).segment_count = @intCast(segments.len);
    publish.publishedRevSide(node_buffer).first_segment = segments[0];
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    var total: usize = 0;
    for (segments) |segment_idx| {
        const segment = page_ops.edgeBlockSegmentAtConst(&graph.graph, segment_idx);
        for (segment.start..segment.start + segment.count) |block_idx| {
            total += page_ops.blockAliveCount(&graph.graph, @intCast(block_idx), .rev);
        }
    }
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast((total))));
    try publish.syncToPublished(graph, node.index);
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination: graph_mod.NodeId, source_idx: u32) !void {
    const block = try graph.allocBlockRev();
    var reverse_block = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    reverse_block.sources[0] = source_idx;
    page_ops.setBlockAliveCount(&graph.graph, block, .rev, 1);

    const node_buffer = try graph.nodeAt(destination);
    publish.publishedRevSide(node_buffer).first_block = block;
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, destination.index);
}

fn publishSingleForwardEdge(graph: *graph_mod.Graph, source: graph_mod.NodeId, destination_idx: u32) !void {
    const block = try graph.allocBlockFwd();
    var forward_block = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    forward_block.destinations[0] = destination_idx;
    forward_block.relations[0] = 0;
    forward_block.flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 1);

    const node_buffer = try graph.nodeAt(source);
    publish.publishedFwdSide(node_buffer).first_block = block;
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, source.index);
}

fn buildSegmentedForwardGraph(graph: *graph_mod.Graph) !graph_mod.NodeId {
    try addNodeCount(graph, 100);
    const source = graph_mod.NodeId{ .index = 0 };

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    const block2 = try graph.allocBlockFwd();
    setForwardBlock(graph, block0, 1, 49);
    setForwardBlock(graph, block1, 50, 49);
    setForwardBlock(graph, block2, 99, 1);

    const segment0 = try graph.allocSegment();
    const segment1 = try graph.allocSegment();
    const segment2 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment0).* = .{ .start = block0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, segment1).* = .{ .start = block1, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, segment2).* = .{ .start = block2, .count = 1 };
    try publishForwardSegments(graph, source, &[_]u32{ segment0, segment1, segment2 }, 3);

    for (1..100) |destination_idx| {
        try publishSingleReverseSource(graph, .{ .index = @intCast(destination_idx) }, source.index);
    }
    graph.graph.edge_count.store(99, .release);
    return source;
}

fn buildSegmentedReverseGraph(graph: *graph_mod.Graph) !graph_mod.NodeId {
    try addNodeCount(graph, 100);
    const destination = graph_mod.NodeId{ .index = 0 };

    const block0 = try graph.allocBlockRev();
    const block1 = try graph.allocBlockRev();
    const block2 = try graph.allocBlockRev();
    setReverseBlock(graph, block0, 1, 49);
    setReverseBlock(graph, block1, 50, 49);
    setReverseBlock(graph, block2, 99, 1);

    const segment0 = try graph.allocSegment();
    const segment1 = try graph.allocSegment();
    const segment2 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment0).* = .{ .start = block0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, segment1).* = .{ .start = block1, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, segment2).* = .{ .start = block2, .count = 1 };
    try publishReverseSegments(graph, destination, &[_]u32{ segment0, segment1, segment2 }, 3);

    for (1..100) |source_idx| {
        try publishSingleForwardEdge(graph, .{ .index = @intCast(source_idx) }, destination.index);
    }
    graph.graph.edge_count.store(99, .release);
    return destination;
}

test "mutation segmented: non-tail and tail removes succeed while occupancy holds" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildSegmentedForwardGraph(&graph);
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

test "mutation segmented: non-tail and tail reverse removes succeed while occupancy holds" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildSegmentedReverseGraph(&graph);
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

test "mutation segmented: RepairRequired in segmented forward does not publish" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildSegmentedForwardGraph(&graph);
    for (1..2) |_| {}
    const first_block_idx = page_ops.edgeBlockSegmentAtConst(&graph.graph, (try graph.publishedNodeAdj(source)).first_segment_fwd).start;
    page_ops.setBlockAliveCount(&graph.graph, first_block_idx, .fwd, @intCast(48));
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

test "mutation segmented: RepairRequired in segmented reverse does not publish" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildSegmentedReverseGraph(&graph);
    const first_block_idx = page_ops.edgeBlockSegmentAtConst(&graph.graph, (try graph.publishedNodeAdj(destination)).first_segment_rev).start;
    page_ops.setBlockAliveCount(&graph.graph, first_block_idx, .rev, @intCast(48));
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

test "mutation segmented: addEdge clones forward segment chain before tail mutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildSegmentedForwardGraph(&graph);
    const before_adj = try graph.publishedNodeAdj(source);
    const first_segment = before_adj.first_segment_fwd;
    const second_segment = first_segment + 1;
    const tail_segment = second_segment + 1;
    const tail_before = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;

    const new_destination = try graph.addNode();
    try graph.addEdge(source, new_destination, 0, 0);

    const tail_after = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expect((try graph.publishedNodeAdj(source)).first_segment_fwd != first_segment);
    try graph.validate();
}

test "mutation segmented: addEdge clones reverse segment chain before tail mutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try buildSegmentedReverseGraph(&graph);
    const before_adj = try graph.publishedNodeAdj(destination);
    const first_segment = before_adj.first_segment_rev;
    const second_segment = first_segment + 1;
    const tail_segment = second_segment + 1;
    const tail_before = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;

    const new_source = try graph.addNode();
    try graph.addEdge(new_source, destination, 0, 0);

    const tail_after = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;
    try testing.expectEqual(tail_before.start, tail_after.start);
    try testing.expectEqual(tail_before.count, tail_after.count);
    try testing.expect((try graph.publishedNodeAdj(destination)).first_segment_rev != first_segment);
    try graph.validate();
}

test "mutation segmented: removeEdge tail block clones chain without mutating published segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try buildSegmentedForwardGraph(&graph);
    const before = try graph.publishedNodeAdj(source);
    const first_segment = before.first_segment_fwd;
    const second_segment = first_segment + 1;
    const tail_segment = second_segment + 1;
    const tail_before = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;

    try testing.expect(try graph.removeEdge(source, .{ .index = 99 }));

    const tail_after_old = page_ops.edgeBlockSegmentAtConst(&graph.graph, tail_segment).*;
    try testing.expectEqual(tail_before.start, tail_after_old.start);
    try testing.expectEqual(tail_before.count, tail_after_old.count);

    const after = try graph.publishedNodeAdj(source);
    try testing.expect(after.first_segment_fwd != first_segment);
    try testing.expectEqual(before.segment_count_fwd - 1, after.segment_count_fwd);
    try testing.expectEqual(before.block_count_fwd - 1, after.block_count_fwd);
    try graph.validate();
}

fn publishSingleBlockSegmentedForward(
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    destination_idx: u32,
) !struct { block: u32, segment: u32 } {
    const block = try graph.allocBlockFwd();
    setForwardBlock(graph, block, destination_idx, 1);
    const segment = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{ .start = block, .count = 1 };

    const node_buffer = try graph.nodeAt(source);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.publishedFwdSide(node_buffer).segment_count = 1;
    publish.publishedFwdSide(node_buffer).first_segment = segment;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(1)));
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(graph, source.index);
    return .{ .block = block, .segment = segment };
}

fn publishSingleBlockSegmentedReverse(
    graph: *graph_mod.Graph,
    destination: graph_mod.NodeId,
    source_idx: u32,
) !struct { block: u32, segment: u32 } {
    const block = try graph.allocBlockRev();
    setReverseBlock(graph, block, source_idx, 1);
    const segment = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{ .start = block, .count = 1 };

    const node_buffer = try graph.nodeAt(destination);
    publish.clearPublishedSides(node_buffer);
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.publishedRevSide(node_buffer).segment_count = 1;
    publish.publishedRevSide(node_buffer).first_segment = segment;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    publish.setPublishedFlags(node_buffer, .{ .needs_repair_fwd = false, .needs_repair_rev = true, .removed = false });
    try publish.syncToPublished(graph, destination.index);
    return .{ .block = block, .segment = segment };
}

test "mutation segmented: addEdge COW on single-block segmented forward updates segment.start" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 4);
    const source = graph_mod.NodeId{ .index = 0 };
    const old_dest = graph_mod.NodeId{ .index = 1 };
    const new_dest = graph_mod.NodeId{ .index = 2 };

    _ = try publishSingleBlockSegmentedForward(&graph, source, old_dest.index);

    // Reverse backlink for old_dest (contiguous, contiguous)
    try publishSingleReverseSource(&graph, old_dest, source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(source, new_dest, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(source));

    const after = graph.nodeRefAny(source).publishedAdj();
    try testing.expectEqual(@as(u16, 0), after.segment_count_fwd);
    try testing.expectEqual(@as(u16, 1), after.block_count_fwd);
    try neighbors.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{ old_dest.index, new_dest.index });
}

test "mutation segmented: removeEdge repacks in-call when COW split exceeds MAX_SEGMENTS_PER_NODE" {
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

    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();
    const g2 = try graph.allocSegment();
    const g3 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{ .start = b2, .count = 3 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g2).* = .{ .start = b6, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g3).* = .{ .start = b8, .count = 1 };

    try publishForwardSegments(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 6);

    // Reverse backlinks for destinations 1..242
    for (1..243) |destination_idx| {
        try publishSingleReverseSource(&graph, .{ .index = @intCast(destination_idx) }, source.index);
    }
    graph.graph.edge_count.store(242, .release);

    // Block 3 has 49 edges. Removing one from a non-tail middle block
    // forces a COW replacement. The new block lands at index 1 (LIFO from
    // the free stack), which would break contiguity of the [2..4] segment and
    // push the side past MAX_SEGMENTS_PER_NODE. The removal performs the
    // synchronous in-call dense repack and succeeds
    // instead of bouncing RepairRequired to the caller.
    try testing.expect(try graph.removeEdge(source, .{ .index = 97 }));

    try graph.validate();
    try testing.expectEqual(@as(u64, 241), graph.edgeCount());
    try testing.expectEqual(@as(usize, 241), try graph.outDegree(source));

    // The repacked side satisfies the segment bound again.
    const adjacency_after = try graph.publishedNodeAdj(source);
    try testing.expect(adjacency_after.segment_count_fwd <= 4);
}

test "mutation segmented: addEdge COW on single-block segmented reverse updates segment.start" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 4);
    const old_source = graph_mod.NodeId{ .index = 0 };
    const destination = graph_mod.NodeId{ .index = 1 };
    const new_source = graph_mod.NodeId{ .index = 2 };

    // Forward on old_source (contiguous)
    try publishSingleForwardEdge(&graph, old_source, destination.index);

    // Reverse on destination: single-block segmented
    _ = try publishSingleBlockSegmentedReverse(&graph, destination, old_source.index);

    graph.graph.edge_count.store(1, .release);
    try graph.validate();

    try graph.addEdge(new_source, destination, 0, 0);

    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(destination));

    const after = try graph.publishedNodeAdj(destination);
    try testing.expectEqual(@as(u16, 0), after.segment_count_rev);
    try testing.expectEqual(@as(u16, 1), after.block_count_rev);
    try neighbors.expectInNeighbors(&graph, testing.allocator, destination, &[_]u32{ old_source.index, new_source.index });
}

test "mutation segmented: addEdge appends past four segments without structural rebuild" {
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

    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();
    const g2 = try graph.allocSegment();
    const g3 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{ .start = b2, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g2).* = .{ .start = b4, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g3).* = .{ .start = b6, .count = 1 };
    try publishForwardSegments(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 4);

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
    try testing.expect(after.segment_count_fwd <= constants.MAX_SEGMENTS_PER_NODE);
    try testing.expectEqual(@as(u16, 5), after.block_count_fwd);
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(.{ .index = 257 }));
}

test "mutation segmented: addEdge replaces partial tail within four-segment limit" {
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

    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();
    const g2 = try graph.allocSegment();
    const g3 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g3).* = .{ .start = b3, .count = 2 };
    try publishForwardSegments(&graph, source, &[_]u32{ g0, g1, g2, g3 }, 5);

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
    try testing.expectEqual(@as(u16, 3), after.segment_count_fwd);
    try testing.expectEqual(@as(u16, 5), after.block_count_fwd);
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(.{ .index = 258 }));
}
