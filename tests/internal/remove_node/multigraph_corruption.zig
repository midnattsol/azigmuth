const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const testing = std.testing;

test "removeNode multigraph corruption: reverse multiplicity exceeding forward is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    try graph.addEdge(source, target, 1, 0);

    const target_node = try graph.nodeAt(target);
    const target_adj = target_node.publishedAdj();
    if (target_adj.block_count_rev > 0 and target_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, target_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = source.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

test "removeNode multigraph corruption: reverse multiplicity below forward is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    try graph.addEdge(source, target, 1, 0);

    const target_node = try graph.nodeAt(target);
    const target_adj = target_node.publishedAdj();
    if (target_adj.block_count_rev > 0 and target_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, target_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live > 0) {
            block.sources[0] = graph.graph.publishedNodeCount() + 10;
            block.mask = constants.denseMask(@intCast(live - 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(target));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

test "removeNode multigraph corruption: corrupt self-edge multiplicity is rejected" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);
    try graph.addEdge(node, node, 1, 0);

    const node_buffer = try graph.nodeAt(node);
    const adj = node_buffer.publishedAdj();
    if (adj.block_count_rev > 0 and adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = node.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(node));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}
