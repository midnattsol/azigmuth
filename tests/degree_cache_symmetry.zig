const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const helpers = @import("helpers.zig");

const testing = std.testing;

test "degree: inDegree at DEGREE_OVERFLOW falls back to O(B) scan" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    for (0..65535) |_| _ = try graph.addNode();

    const blocks_needed = 65536 / 64;
    var first_block: u32 = 0;
    for (0..blocks_needed) |chunk| {
        const b = try graph.allocBlockRev();
        if (chunk == 0) first_block = b;
        var blk = page_ops.edgeBlockAt(&graph.graph, b, .rev);
        for (0..64) |j| {
            blk.sources[j] = @intCast(chunk * 64 + j);
        }
        blk.mask = constants.FULL_BLOCK_MASK;
    }

    const node = try graph.nodeAt(hub);
    helpers.publishedRevSide(node).first_block = first_block;
    helpers.publishedRevSide(node).block_count = @intCast(blocks_needed);
    node.degree_rev = constants.DEGREE_OVERFLOW;
    graph.graph.edge_count.store(65536, .release);

    try testing.expectEqual(@as(usize, 65536), try graph.inDegree(hub));
    try testing.expectEqual(constants.DEGREE_OVERFLOW, node.degree_rev);
}

test "degree: outDegree at DEGREE_OVERFLOW falls back to O(B) scan" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..65535) |_| _ = try graph.addNode();

    const blocks_needed = 65536 / 64;
    var first_block: u32 = 0;
    for (0..blocks_needed) |chunk| {
        const b = try graph.allocBlockFwd();
        if (chunk == 0) first_block = b;
        var blk = page_ops.edgeBlockAt(&graph.graph, b, .fwd);
        for (0..64) |j| {
            blk.edges[j] = .{ .destination = @intCast(chunk * 64 + j), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
        }
        blk.mask = constants.FULL_BLOCK_MASK;
    }

    const node = try graph.nodeAt(src);
    helpers.publishedFwdSide(node).first_block = first_block;
    helpers.publishedFwdSide(node).block_count = @intCast(blocks_needed);
    node.degree_fwd = constants.DEGREE_OVERFLOW;
    graph.graph.edge_count.store(65536, .release);

    try testing.expectEqual(@as(usize, 65536), try graph.outDegree(src));
    try testing.expectEqual(constants.DEGREE_OVERFLOW, node.degree_fwd);
}
