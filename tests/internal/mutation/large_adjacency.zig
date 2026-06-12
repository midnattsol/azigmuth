const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");
const AdjSide = graph_mod.adjacency_mod.AdjSide;

const testing = std.testing;

fn fillBlock(graph: *graph_mod.Graph, block_idx: u32, first_dest: u32, count: u7, comptime side: AdjSide) void {
    switch (side) {
        .fwd => {
            var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
            for (0..count) |i| {
                block.destinations[i] = first_dest + @as(u32, @intCast(i));
                block.relations[i] = 0;
                block.flags[i] = 0;
            }
            page_ops.setBlockLiveCount(&graph.graph, block_idx, .fwd, @intCast(count));
        },
        .rev => {
            var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
            for (0..count) |i| {
                block.sources[i] = first_dest + @as(u32, @intCast(i));
            }
            page_ops.setBlockLiveCount(&graph.graph, block_idx, .rev, @intCast(count));
        },
    }
}

fn publishReverseSource(graph: *graph_mod.Graph, destination_idx: u32, source_idx: u32) !void {
    const block = try graph.allocBlockRev();
    fillBlock(graph, block, source_idx, 1, .rev);
    const node = try graph.nodeAt(.{ .index = destination_idx });
    publish.clearPublishedSides(node);
    publish.publishedRevSide(node).first_block = block;
    publish.publishedRevSide(node).block_count = 1;
    publish.setPublishedRevDegree(node, 1);
    try publish.syncToPublished(graph, destination_idx);
}

test "large adjacency: removeEdge from tail block preserves all blocks when adjacency has >128 blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block_count: u16 = 130;
    const source = try graph.addNode();
    for (0..block_count) |_| { _ = try graph.addNode(); }

    var blocks: [block_count]u32 = undefined;
    for (0..block_count) |i| {
        blocks[i] = try graph.allocBlockFwd();
        fillBlock(&graph, blocks[i], @intCast(i + 1), 1, .fwd);
    }

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).first_block = blocks[0];
    publish.publishedFwdSide(source_node).block_count = block_count;
    publish.publishedFwdSide(source_node).group_count = 0;
    publish.setPublishedFwdDegree(source_node, block_count);
    publish.setPublishedFlags(source_node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, source.index);

    for (1..block_count + 1) |dest_idx| {
        try publishReverseSource(&graph, @intCast(dest_idx), source.index);
    }
    graph.graph.edge_count.store(block_count, .release);

    // Remove from the tail block (is_tail → no RepairRequired)
    try testing.expect(try graph.removeEdge(source, .{ .index = block_count }));

    const after = try graph.publishedNodeAdj(source);
    try testing.expectEqual(@as(u16, block_count - 1), after.block_count_fwd);
    try testing.expectEqual(@as(u16, 0), after.group_count_fwd);
    try testing.expectEqual(@as(u64, block_count - 1), graph.edgeCount());
}

test "large adjacency: addEdge COW preserves all blocks when adjacency has >128 blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block_count: u16 = 130;
    const source = try graph.addNode();
    for (0..block_count) |_| { _ = try graph.addNode(); }

    var blocks: [block_count]u32 = undefined;
    for (0..block_count) |i| {
        blocks[i] = try graph.allocBlockFwd();
        if (i == block_count - 1) {
            fillBlock(&graph, blocks[i], 1, 63, .fwd);
        }
    }

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).first_block = blocks[0];
    publish.publishedFwdSide(source_node).block_count = block_count;
    publish.publishedFwdSide(source_node).group_count = 0;
    publish.setPublishedFwdDegree(source_node, 63);
    publish.setPublishedFlags(source_node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    try publish.syncToPublished(&graph, source.index);

    for (0..63) |j| {
        try publishReverseSource(&graph, 1 + @as(u32, @intCast(j)), source.index);
    }
    graph.graph.edge_count.store(63, .release);

    const new_dest = graph_mod.NodeId{ .index = 64 };
    try graph.addEdge(source, new_dest, 0, 0);

    const after = try graph.publishedNodeAdj(source);
    try testing.expectEqual(@as(u16, block_count), after.block_count_fwd);
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "large adjacency: addEdge tail COW does not reject when MAX_GROUPS_PER_NODE tail group has single block" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const total_dest: u32 = (4 * 64) + 1;
    const source = try graph.addNode();
    for (0..total_dest) |_| { _ = try graph.addNode(); }

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const b3 = try graph.allocBlockFwd();
    fillBlock(&graph, b0, 1, 64, .fwd);
    fillBlock(&graph, b1, 65, 64, .fwd);
    fillBlock(&graph, b2, 129, 64, .fwd);
    fillBlock(&graph, b3, 193, 64, .fwd);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    const g3 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1 };
    page_ops.groupAt(&graph.graph, g3).* = .{ .start = b3, .count = 1 };

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).block_count = 4;
    publish.publishedFwdSide(source_node).group_count = 4;
    publish.publishedFwdSide(source_node).first_group = g0;
    publish.setPublishedFlags(source_node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    publish.setPublishedFwdDegree(source_node, 256);
    try publish.syncToPublished(&graph, source.index);

    for (1..257) |dest_idx| {
        try publishReverseSource(&graph, @intCast(dest_idx), source.index);
    }
    graph.graph.edge_count.store(256, .release);

    const new_dest = graph_mod.NodeId{ .index = total_dest };
    try graph.addEdge(source, new_dest, 0, 0);

    try testing.expectEqual(@as(u64, 257), graph.edgeCount());
    try testing.expectEqual(@as(usize, 257), try graph.outDegree(source));
}
