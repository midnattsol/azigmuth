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
    for (0..8) |i| nodes[i] = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    for (0..8) |i| {
        blk.destinations[i] = nodes[i].index;
        blk.relations[i] = 0;
        blk.flags[i] = 0;
    }
    blk.mask = constants.denseMask(8);

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

    try testing.expectEqual(@as(usize, 6), result.live_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .fwd);
    const expected_indices = [_]u32{ 0, 1, 3, 4, 6, 7 };
    for (expected_indices, 0..) |expected_idx, i| {
        try testing.expectEqual(expected_idx, out_blk.destinations[i]);
    }
    try testing.expectEqual(constants.denseMask(6), out_blk.mask);
}

test "sorted rebuild forward: all tombstones returns empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |i| nodes[i] = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    for (0..3) |i| {
        blk.destinations[i] = nodes[i].index;
        blk.relations[i] = 0;
        blk.flags[i] = 0;
    }
    blk.mask = constants.denseMask(3);

    for (0..3) |i| _ = try graph.removeNode(nodes[i]);

    var result = try repair.sortedRebuildForward(
        &graph.graph,
        block,
        1,
        0,
        0,
        testing.allocator,
    );
    defer result.new_blocks.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.live_after);
    try testing.expectEqual(@as(usize, 0), result.new_blocks.items.len);
}

test "sorted rebuild reverse: removes tombstones and packs sorted sources" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..8) |i| nodes[i] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..8) |i| {
        blk.sources[i] = nodes[i].index;
    }
    blk.mask = constants.denseMask(8);

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

    try testing.expectEqual(@as(usize, 6), result.live_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .rev);
    const expected_indices = [_]u32{ 0, 1, 3, 4, 6, 7 };
    for (expected_indices, 0..) |expected_idx, i| {
        try testing.expectEqual(expected_idx, out_blk.sources[i]);
    }
    try testing.expectEqual(constants.denseMask(6), out_blk.mask);
}

test "sorted rebuild reverse: skip_source_index excludes the requested source" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [5]graph_mod.NodeId = undefined;
    for (0..5) |i| nodes[i] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..5) |i| {
        blk.sources[i] = nodes[i].index;
    }
    blk.mask = constants.denseMask(5);

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

    try testing.expectEqual(@as(usize, 4), result.live_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .rev);
    const expected_indices = [_]u32{ 0, 1, 3, 4 };
    for (expected_indices, 0..) |expected_idx, i| {
        try testing.expectEqual(expected_idx, out_blk.sources[i]);
    }
    try testing.expectEqual(constants.denseMask(4), out_blk.mask);
}

test "sorted rebuild reverse: all tombstones returns empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |i| nodes[i] = try graph.addNode();

    const block = try graph.allocBlockRev();
    var blk = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    for (0..3) |i| {
        blk.sources[i] = nodes[i].index;
    }
    blk.mask = constants.denseMask(3);

    for (0..3) |i| _ = try graph.removeNode(nodes[i]);

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

    try testing.expectEqual(@as(usize, 0), result.live_after);
    try testing.expectEqual(@as(usize, 0), result.new_blocks.items.len);
}

test "sorted rebuild forward: two blocks with mixed tombstones produce packed output" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [12]graph_mod.NodeId = undefined;
    for (0..12) |i| nodes[i] = try graph.addNode();

    const block0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    for (0..6) |i| {
        blk0.destinations[i] = nodes[i].index;
        blk0.relations[i] = 0;
        blk0.flags[i] = 0;
    }
    blk0.mask = constants.denseMask(6);

    const block1 = try graph.allocBlockFwd();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);
    for (6..12) |i| {
        blk1.destinations[i - 6] = nodes[i].index;
        blk1.relations[i - 6] = 0;
        blk1.flags[i - 6] = 0;
    }
    blk1.mask = constants.denseMask(6);

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

    try testing.expectEqual(@as(usize, 10), result.live_after);
    try testing.expectEqual(@as(usize, 1), result.new_blocks.items.len);

    const out_blk = page_ops.edgeBlockAt(&graph.graph, result.new_blocks.items[0], .fwd);
    const expected_indices = [_]u32{ 0, 1, 2, 4, 5, 6, 7, 9, 10, 11 };
    for (expected_indices, 0..) |expected_idx, i| {
        try testing.expectEqual(expected_idx, out_blk.destinations[i]);
    }
    try testing.expectEqual(constants.denseMask(10), out_blk.mask);
}
