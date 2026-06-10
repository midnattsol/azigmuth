const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");
const testing = std.testing;

test "removeNode corruption: grouped forward chain shorter than declared group count is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const dest_a = try graph.addNode();
    const dest_b = try graph.addNode();

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[0] = dest_a.index;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).flags[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).destinations[0] = dest_b.index;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).flags[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = constants.END_OF_CHAIN };

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).block_count = 2;
    publish.publishedFwdSide(source_node).group_count = 2;
    publish.publishedFwdSide(source_node).first_group = g0;
    publish.setPublishedFwdDegree(source_node, 2);
    try publish.syncToPublished(&graph, source.index);
    {
        const block = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, block, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, block, .rev).mask = constants.denseMask(1);
        const node = try graph.nodeAt(dest_a);
        publish.clearPublishedSides(node);
        publish.publishedRevSide(node).first_block = block;
        publish.publishedRevSide(node).block_count = 1;
        publish.setPublishedRevDegree(node, 1);
        try publish.syncToPublished(&graph, dest_a.index);
    }
    {
        const block = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, block, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, block, .rev).mask = constants.denseMask(1);
        const node = try graph.nodeAt(dest_b);
        publish.clearPublishedSides(node);
        publish.publishedRevSide(node).first_block = block;
        publish.publishedRevSide(node).block_count = 1;
        publish.setPublishedRevDegree(node, 1);
        try publish.syncToPublished(&graph, dest_b.index);
    }

    graph.graph.edge_count.store(2, .release);
    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(try graph.nodeAt(dest_b)).rev);
}

test "removeNode corruption: invalid forward first_group is rejected before traversal" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).block_count = 1;
    publish.publishedFwdSide(source_node).group_count = 1;
    publish.publishedFwdSide(source_node).first_group = graph.graph.group_count + 10;
    publish.setPublishedFwdDegree(source_node, 1);
    try publish.syncToPublished(&graph, source.index);

    const reverse_block = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, reverse_block, .rev).sources[0] = source.index;
    page_ops.edgeBlockAt(&graph.graph, reverse_block, .rev).mask = constants.denseMask(1);
    const destination_node = try graph.nodeAt(destination);
    publish.clearPublishedSides(destination_node);
    publish.publishedRevSide(destination_node).first_block = reverse_block;
    publish.publishedRevSide(destination_node).block_count = 1;
    publish.setPublishedRevDegree(destination_node, 1);
    try publish.syncToPublished(&graph, destination.index);

    graph.graph.edge_count.store(1, .release);
    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(destination_node).rev);
}

test "removeNode corruption: truncated grouped forward chain with skipped live destination is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const dest_a = try graph.addNode();
    const dest_b = try graph.addNode();

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[0] = dest_a.index;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).flags[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).destinations[0] = dest_b.index;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).flags[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = constants.END_OF_CHAIN };

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).block_count = 2;
    publish.publishedFwdSide(source_node).group_count = 2;
    publish.publishedFwdSide(source_node).first_group = g0;
    publish.setPublishedFwdDegree(source_node, 2);
    try publish.syncToPublished(&graph, source.index);
    {
        const block = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, block, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, block, .rev).mask = constants.denseMask(1);
        const node = try graph.nodeAt(dest_a);
        publish.clearPublishedSides(node);
        publish.publishedRevSide(node).first_block = block;
        publish.publishedRevSide(node).block_count = 1;
        publish.setPublishedRevDegree(node, 1);
        try publish.syncToPublished(&graph, dest_a.index);
    }
    {
        const block = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, block, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, block, .rev).mask = constants.denseMask(1);
        const node = try graph.nodeAt(dest_b);
        publish.clearPublishedSides(node);
        publish.publishedRevSide(node).first_block = block;
        publish.publishedRevSide(node).block_count = 1;
        publish.setPublishedRevDegree(node, 1);
        try publish.syncToPublished(&graph, dest_b.index);
    }

    graph.graph.edge_count.store(2, .release);
    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(try graph.nodeAt(dest_b)).rev);
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(try graph.nodeAt(dest_a)).rev);
}

test "removeNode corruption: grouped reverse chain shorter than declared group count is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const src_a = try graph.addNode();
    const src_b = try graph.addNode();

    {
        const block = try graph.allocBlockFwd();
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = target.index;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
        const node = try graph.nodeAt(src_a);
        publish.clearPublishedSides(node);
        publish.publishedFwdSide(node).first_block = block;
        publish.publishedFwdSide(node).block_count = 1;
        publish.setPublishedFwdDegree(node, 1);
        try publish.syncToPublished(&graph, src_a.index);
    }
    {
        const block = try graph.allocBlockFwd();
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = target.index;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
        const node = try graph.nodeAt(src_b);
        publish.clearPublishedSides(node);
        publish.publishedFwdSide(node).first_block = block;
        publish.publishedFwdSide(node).block_count = 1;
        publish.setPublishedFwdDegree(node, 1);
        try publish.syncToPublished(&graph, src_b.index);
    }

    const r0 = try graph.allocBlockRev();
    const r1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).sources[0] = src_a.index;
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).sources[0] = src_b.index;
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = r0, .count = 1, .next = constants.END_OF_CHAIN };

    const target_node = try graph.nodeAt(target);
    publish.clearPublishedSides(target_node);
    publish.publishedRevSide(target_node).block_count = 2;
    publish.publishedRevSide(target_node).group_count = 2;
    publish.publishedRevSide(target_node).first_group = g0;
    publish.setPublishedRevDegree(target_node, 2);
    try publish.syncToPublished(&graph, target.index);
    graph.graph.edge_count.store(2, .release);
    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(try graph.nodeAt(src_a)).fwd);
    try testing.expectEqual(@as(u22, 1), publish.publishedDegrees(try graph.nodeAt(src_b)).fwd);
}

test "removeNode corruption: visible predecessor still gets repair debt when reverse chain is truncated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();

    {
        const block = try graph.allocBlockFwd();
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = target.index;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
        page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
        const node = try graph.nodeAt(predecessor);
        publish.clearPublishedSides(node);
        publish.publishedFwdSide(node).first_block = block;
        publish.publishedFwdSide(node).block_count = 1;
        publish.setPublishedFwdDegree(node, 1);
        try publish.syncToPublished(&graph, predecessor.index);
    }

    const r0 = try graph.allocBlockRev();
    const r1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).sources[0] = predecessor.index;
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).sources[0] = predecessor.index;
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = r0, .count = 1, .next = constants.END_OF_CHAIN };

    const target_node = try graph.nodeAt(target);
    publish.clearPublishedSides(target_node);
    publish.publishedRevSide(target_node).block_count = 2;
    publish.publishedRevSide(target_node).group_count = 2;
    publish.publishedRevSide(target_node).first_group = g0;
    publish.setPublishedRevDegree(target_node, 2);
    try publish.syncToPublished(&graph, target.index);
    graph.graph.edge_count.store(1, .release);
    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
}

test "removeNode corruption: out-of-range destination via grouped chain is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    _ = try graph.addNode();

    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = 0xFFFFFFFF;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);

    const group = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = constants.END_OF_CHAIN };

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).block_count = 1;
    publish.publishedFwdSide(source_node).group_count = 1;
    publish.publishedFwdSide(source_node).first_group = group;
    publish.setPublishedFwdDegree(source_node, 1);
    try publish.syncToPublished(&graph, source.index);

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}
