const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const types = test_internals.types;
const testing = std.testing;

test "regression: removeNode reverse-only publish does not flip forward index of related nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const fwd_index_before = b_node.loadPublishedMeta().fwd_index;

    try graph.removeNode(a);

    const fwd_index_after = b_node.loadPublishedMeta().fwd_index;
    try testing.expectEqual(fwd_index_before, fwd_index_after);
    try graph.validate();
}

test "regression: removeNode returns CorruptGraph when reverse backlink is missing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();

    // Remove the reverse entry for A manually, making forward/reverse inconsistent.
    if (b_adj.block_count_rev > 0 and b_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        var found = false;
        for (0..live) |slot| {
            if (block.sources[slot] == a.index) {
                // Overwrite with a value > node_count so it looks "live" but wrong
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: removeNode returns CorruptGraph when reverse backlink is duplicated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();

    // Find a slot that doesn't contain A and overwrite it with A, creating a duplicate.
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

test "regression: validate and debugValidate agree on removed node with residual reverse" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const spoke_count: usize = 10;
    var spokes: [spoke_count]graph_mod.NodeId = undefined;
    for (0..spoke_count) |i| {
        spokes[i] = try graph.addNode();
        try graph.addEdge(spokes[i], hub, 0, 0);
    }

    // Remove half the spokes, leaving tombstones in hub's reverse adjacency.
    for (0..spoke_count) |i| {
        if (i % 2 == 0) try graph.removeNode(spokes[i]);
    }

    // Both validators must pass.
    try graph.validate();
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
