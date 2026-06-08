const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");
const testing = std.testing;

test "removeNode corruption: missing reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();
    if (b_adj.block_count_rev > 0 and b_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        var found = false;
        for (0..live) |slot| {
            if (block.sources[slot] == a.index) {
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "removeNode corruption: duplicated reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();
    if (b_adj.block_count_rev > 0 and b_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = a.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "removeNode corruption: missing incoming reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);

    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_rev > 0 and a_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        var found = false;
        for (0..live) |slot| {
            if (block.sources[slot] == b.index) {
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "removeNode corruption: duplicated incoming reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0);

    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_rev > 0 and a_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = b.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "removeNode corruption: duplicated outgoing forward destination is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_fwd > 0 and a_adj.group_count_fwd == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_fwd, .fwd);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.edges[live] = block.edges[live - 1];
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "removeNode corruption: forward destination out of range is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const adj = page_ops.nodeAtConst(&graph.graph, source).publishedAdj();
    if (adj.block_count_fwd > 0 and adj.group_count_fwd == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, adj.first_block_fwd, .fwd);
        block.edges[0].destination = graph.graph.publishedNodeCount() + 1;
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}
