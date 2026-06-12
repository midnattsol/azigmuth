const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");
const testing = std.testing;

test "removeNode regression: reverse-only publish does not flip forward index of related nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const fwd_idx_before = b_node.loadPublishedMeta().fwd_idx;

    _ = try graph.removeNode(a);

    const fwd_idx_after = b_node.loadPublishedMeta().fwd_idx;
    try testing.expectEqual(fwd_idx_before, fwd_idx_after);
    try graph.validate();
}

test "removeNode regression: validate and debugValidate agree on removed node with empty reverse" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const spoke_count: usize = 10;
    var spokes: [spoke_count]graph_mod.NodeId = undefined;
    for (0..spoke_count) |spoke_idx| {
        spokes[spoke_idx] = try graph.addNode();
        try graph.addEdge(spokes[spoke_idx], hub, 0, 0);
    }

    for (0..spoke_count) |spoke_idx| {
        if (spoke_idx % 2 == 0) _ = try graph.removeNode(spokes[spoke_idx]);
    }

    try graph.validate();
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);

    for (0..spoke_count) |spoke_idx| {
        if (spoke_idx % 2 == 0) {
            const removed_adj = graph.nodeRefAny(spokes[spoke_idx]).publishedAdj();
            try testing.expectEqual(@as(u16, 0), removed_adj.block_count_rev);
            try testing.expectEqual(@as(u16, 0), removed_adj.group_count_rev);
        }
    }
}

test "removeNode regression: validate and debugValidate agree on grouped chain shorter than declared group count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    const block = try graph.allocBlockFwd();
    const group = try graph.allocGroup();
    page_ops.setBlockLiveCount(&graph.graph, block, .fwd, @intCast(1));
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 2;
    publish.publishedFwdSide(node_buffer).group_count = 2;
    publish.publishedFwdSide(node_buffer).first_group = group;
    publish.setPublishedFwdDegree(node_buffer, 2);
    try publish.syncToPublished(&graph, node.index);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
