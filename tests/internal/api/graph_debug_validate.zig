const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const Graph = graph_mod.Graph;
const testing = std.testing;

test "graph debug validate: detects forward entry without reverse entry" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    fwd.destinations[0] = b.index;
    fwd.relations[0] = 0;
    fwd.flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, block, .fwd, @intCast(1));

    const a_node = try graph.nodeAt(a);
    publish.clearPublishedSides(a_node);
    publish.publishedFwdSide(a_node).first_block = block;
    publish.publishedFwdSide(a_node).block_count = 1;
    try publish.syncToPublished(&graph, a.index);
    graph.graph.edge_count.store(1, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == a.index and payload.dst == b.index),
        else => {},
    };
    try testing.expect(found);
}

test "graph debug validate: detects removed node with outgoing adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const live = try graph.addNode();
    _ = try graph.removeNode(removed);

    const fwd_block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, fwd_block, .fwd);
    fwd.destinations[0] = live.index;
    fwd.relations[0] = 0;
    fwd.flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, fwd_block, .fwd, @intCast(1));

    const rev_block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, rev_block, .rev);
    rev.sources[0] = removed.index;
    page_ops.setBlockLiveCount(&graph.graph, rev_block, .rev, @intCast(1));

    const removed_raw = graph.nodeRefAny(removed);
    publish.publishedFwdSide(removed_raw).first_block = fwd_block;
    publish.publishedFwdSide(removed_raw).block_count = 1;
    publish.setPublishedFlags(removed_raw, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = true });
    publish.setPublishedFwdDegree(removed_raw, @as(u22, @intCast(1)));
    try publish.syncToPublished(&graph, removed.index);

    const live_raw = try graph.nodeAt(live);
    publish.publishedRevSide(live_raw).first_block = rev_block;
    publish.publishedRevSide(live_raw).block_count = 1;
    publish.setPublishedRevDegree(live_raw, @as(u22, @intCast(1)));
    try publish.syncToPublished(&graph, live.index);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found_outgoing = false;
    var found_repair_flag = false;
    for (violations) |violation| switch (violation) {
        .removed_node_has_outgoing => |payload| found_outgoing = found_outgoing or payload.node == removed.index,
        .removed_node_marked_for_repair => |payload| found_repair_flag = found_repair_flag or payload.node == removed.index,
        else => {},
    };
    try testing.expect(found_outgoing);
    try testing.expect(found_repair_flag);
}

test "graph debug validate: detects reverse entry without forward entry" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    rev.sources[0] = a.index;
    page_ops.setBlockLiveCount(&graph.graph, block, .rev, @intCast(1));

    const b_node = try graph.nodeAt(b);
    publish.clearPublishedSides(b_node);
    publish.publishedRevSide(b_node).first_block = block;
    publish.publishedRevSide(b_node).block_count = 1;
    try publish.syncToPublished(&graph, b.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == a.index and payload.dst == b.index),
        else => {},
    };
    try testing.expect(found);
}
