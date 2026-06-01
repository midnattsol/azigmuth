const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;

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
    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].block_count_fwd = block_count;
    node_buffer.adj_buffers[0].group_count_fwd = @intCast(groups.len);
    node_buffer.adj_buffers[0].first_group_fwd = groups[0];
    node_buffer.storePublishedAdjIndex(0);
}

fn publishReverseGroups(graph: *graph_mod.Graph, node: graph_mod.NodeId, groups: []const u32, block_count: u16) !void {
    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].block_count_rev = block_count;
    node_buffer.adj_buffers[0].group_count_rev = @intCast(groups.len);
    node_buffer.adj_buffers[0].first_group_rev = groups[0];
    node_buffer.storePublishedAdjIndex(0);
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination: graph_mod.NodeId, source_index: u32) !void {
    const block = try graph.allocBlockRev();
    var reverse_block = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    reverse_block.sources[0] = source_index;
    reverse_block.mask = constants.denseMask(1);

    var node_buffer = try graph.nodeAt(destination);
    node_buffer.adj_buffers[0].first_block_rev = block;
    node_buffer.adj_buffers[0].block_count_rev = 1;
}

fn publishSingleForwardEdge(graph: *graph_mod.Graph, source: graph_mod.NodeId, destination_index: u32) !void {
    const block = try graph.allocBlockFwd();
    var forward_block = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    forward_block.edges[0] = .{ .destination = destination_index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    forward_block.mask = constants.denseMask(1);

    var node_buffer = try graph.nodeAt(source);
    node_buffer.adj_buffers[0].first_block_fwd = block;
    node_buffer.adj_buffers[0].block_count_fwd = 1;
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
    (try graph.nodeAt(.{ .index = 49 })).adj_buffers[0].block_count_rev = 0;
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
    (try graph.nodeAt(.{ .index = 49 })).adj_buffers[0].block_count_fwd = 0;
    graph.graph.edge_count.store(98, .release);

    try testing.expectError(error.RepairRequired, graph.removeEdge(.{ .index = 1 }, destination));
    try testing.expectEqual(@as(u64, 98), graph.edgeCount());
    try graph.validate();
}
