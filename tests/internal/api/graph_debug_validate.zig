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

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    fwd.destinations[0] = destination.index;
    fwd.relations[0] = 0;
    fwd.flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(1));

    const source_node = try graph.nodeAt(source);
    publish.clearPublishedSides(source_node);
    publish.publishedFwdSide(source_node).first_block = block;
    publish.publishedFwdSide(source_node).block_count = 1;
    try publish.syncToPublished(&graph, source.index);
    graph.graph.edge_count.store(1, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == source.index and payload.destination == destination.index),
        else => {},
    };
    try testing.expect(found);
}

test "graph debug validate: detects removed node with outgoing adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const alive = try graph.addNode();
    _ = try graph.removeNode(removed);

    const fwd_block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, fwd_block, .fwd);
    fwd.destinations[0] = alive.index;
    fwd.relations[0] = 0;
    fwd.flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, fwd_block, .fwd, @intCast(1));

    const rev_block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, rev_block, .rev);
    rev.sources[0] = removed.index;
    page_ops.setBlockAliveCount(&graph.graph, rev_block, .rev, @intCast(1));

    const removed_raw = graph.nodeRefAny(removed);
    publish.publishedFwdSide(removed_raw).first_block = fwd_block;
    publish.publishedFwdSide(removed_raw).block_count = 1;
    publish.setPublishedFlags(removed_raw, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = true });
    publish.setPublishedFwdDegree(removed_raw, @as(u22, @intCast(1)));
    try publish.syncToPublished(&graph, removed.index);

    const live_raw = try graph.nodeAt(alive);
    publish.publishedRevSide(live_raw).first_block = rev_block;
    publish.publishedRevSide(live_raw).block_count = 1;
    publish.setPublishedRevDegree(live_raw, @as(u22, @intCast(1)));
    try publish.syncToPublished(&graph, alive.index);
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

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    rev.sources[0] = source.index;
    page_ops.setBlockAliveCount(&graph.graph, block, .rev, @intCast(1));

    const destination_node = try graph.nodeAt(destination);
    publish.clearPublishedSides(destination_node);
    publish.publishedRevSide(destination_node).first_block = block;
    publish.publishedRevSide(destination_node).block_count = 1;
    try publish.syncToPublished(&graph, destination.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == source.index and payload.destination == destination.index),
        else => {},
    };
    try testing.expect(found);
}
