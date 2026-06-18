const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const repair = graph_mod.repair_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

test "sorted rebuild forward: removes tombstones and packs sorted edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..8) |node_idx| nodes[node_idx] = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    for (0..8) |slot_idx| {
        blk.destinations[slot_idx] = nodes[slot_idx].index;
        blk.relations[slot_idx] = 0;
        blk.flags[slot_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(8));

    _ = try graph.removeNode(nodes[2]);
    _ = try graph.removeNode(nodes[5]);

    var result = try repair.sortedRebuildForward(
        &graph.graph,
        block,
        1,
        0,
        0,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), result.alive_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .fwd);
    const expected_indices = [_]u32{ 0, 1, 3, 4, 6, 7 };
    for (expected_indices, 0..) |expected_idx, slot_idx| {
        try testing.expectEqual(expected_idx, out_blk.destinations[slot_idx]);
    }
    try testing.expectEqual(@as(u7, 6), page_ops.blockAliveCount(&graph.graph, result.new_blocks.items[0], .fwd));
}

test "sorted rebuild forward: all tombstones returns empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |node_idx| nodes[node_idx] = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    for (0..3) |slot_idx| {
        blk.destinations[slot_idx] = nodes[slot_idx].index;
        blk.relations[slot_idx] = 0;
        blk.flags[slot_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(3));

    for (0..3) |node_idx| _ = try graph.removeNode(nodes[node_idx]);

    var result = try repair.sortedRebuildForward(
        &graph.graph,
        block,
        1,
        0,
        0,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.alive_after);
    try testing.expectEqual(@as(usize, 0), result.new_blocks.items.len);
}

test "sorted rebuild reverse: removes tombstones and packs sorted sources" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..8) |node_idx| nodes[node_idx] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..8) |slot_idx| {
        blk.sources[slot_idx] = nodes[slot_idx].index;
    }
    page_ops.setBlockAliveCount(&graph.graph, block, .rev, @intCast(8));

    _ = try graph.removeNode(nodes[2]);
    _ = try graph.removeNode(nodes[5]);

    var result = try repair.sortedRebuildReverse(
        &graph.graph,
        block,
        1,
        0,
        0,
        null,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), result.alive_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .rev);
    const expected_indices = [_]u32{ 0, 1, 3, 4, 6, 7 };
    for (expected_indices, 0..) |expected_idx, slot_idx| {
        try testing.expectEqual(expected_idx, out_blk.sources[slot_idx]);
    }
    try testing.expectEqual(@as(u7, 6), page_ops.blockAliveCount(&graph.graph, result.new_blocks.items[0], .rev));
}

test "sorted rebuild reverse: skip_source_idx excludes the requested source" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..5) |node_idx| nodes[node_idx] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..5) |slot_idx| {
        blk.sources[slot_idx] = nodes[slot_idx].index;
    }
    page_ops.setBlockAliveCount(&graph.graph, block, .rev, @intCast(5));

    var result = try repair.sortedRebuildReverse(
        &graph.graph,
        block,
        1,
        0,
        0,
        nodes[2].index,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), result.alive_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .rev);
    const expected_indices = [_]u32{ 0, 1, 3, 4 };
    for (expected_indices, 0..) |expected_idx, slot_idx| {
        try testing.expectEqual(expected_idx, out_blk.sources[slot_idx]);
    }
    try testing.expectEqual(@as(u7, 4), page_ops.blockAliveCount(&graph.graph, result.new_blocks.items[0], .rev));
}

test "sorted rebuild reverse: all tombstones returns empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |node_idx| nodes[node_idx] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..3) |slot_idx| {
        blk.sources[slot_idx] = nodes[slot_idx].index;
    }
    page_ops.setBlockAliveCount(&graph.graph, block, .rev, @intCast(3));

    for (0..3) |node_idx| _ = try graph.removeNode(nodes[node_idx]);

    var result = try repair.sortedRebuildReverse(
        &graph.graph,
        block,
        1,
        0,
        0,
        null,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.alive_after);
    try testing.expectEqual(@as(usize, 0), result.new_blocks.items.len);
}

test "sorted rebuild forward: two blocks with mixed tombstones produce packed output" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [12]graph_mod.NodeId = undefined;
    for (0..12) |node_idx| nodes[node_idx] = try graph.addNode();

    const block0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    for (0..6) |slot_idx| {
        blk0.destinations[slot_idx] = nodes[slot_idx].index;
        blk0.relations[slot_idx] = 0;
        blk0.flags[slot_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block0, .fwd, @intCast(6));

    const block1 = try graph.allocBlockFwd();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);
    for (6..12) |node_idx| {
        blk1.destinations[node_idx - 6] = nodes[node_idx].index;
        blk1.relations[node_idx - 6] = 0;
        blk1.flags[node_idx - 6] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block1, .fwd, @intCast(6));

    // Use adjacency API to set up contiguous blocks
    const node = try graph.nodeAt(nodes[11]);
    const pfwd = publish.publishedFwdSide(node);
    pfwd.first_block = block0;
    pfwd.block_count = 2;
    try publish.syncToPublished(&graph, nodes[11].index);

    _ = try graph.removeNode(nodes[3]);
    _ = try graph.removeNode(nodes[8]);

    var result = try repair.sortedRebuildForward(
        &graph.graph,
        block0,
        2,
        0,
        0,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 10), result.alive_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .fwd);
    const expected_indices = [_]u32{ 0, 1, 2, 4, 5, 6, 7, 9, 10, 11 };
    for (expected_indices, 0..) |expected_idx, slot_idx| {
        try testing.expectEqual(expected_idx, out_blk.destinations[slot_idx]);
    }
    try testing.expectEqual(@as(u7, 10), page_ops.blockAliveCount(&graph.graph, result.new_blocks.items[0], .fwd));
}
