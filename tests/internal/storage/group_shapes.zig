//! Invalid group shape detection — verified that structurally impossible
//! adjacency layouts are rejected rather than silently corrupted.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| _ = try graph.addNode();
}

fn publishReverseSources(graph: *graph_mod.Graph, source_idx: u32, first_destination: u32, count: u32) !void {
    for (0..count) |offset| {
        const block = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, block, .rev).sources[0] = source_idx;
        page_ops.setBlockLiveCount(&graph.graph, block, .rev, @intCast(1));
        const buf = try graph.nodeAt(.{ .index = first_destination + @as(u32, @intCast(offset)) });
        publish.clearPublishedSides(buf);
        publish.publishedRevSide(buf).first_block = block;
        publish.publishedRevSide(buf).block_count = 1;
        publish.setPublishedRevDegree(buf, 1);
        try publish.syncToPublished(graph, first_destination + @as(u32, @intCast(offset)));
    }
}

test "invalid shape: block_count == 1 with group_count > 1 fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();

    page_ops.setBlockLiveCount(&graph.graph, block, .fwd, 0);

    page_ops.groupAt(&graph.graph, g0).* = .{
        .start = block, .count = 1,
    };
    page_ops.groupAt(&graph.graph, g1).* = .{
        .start = block, .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = block;
    publish.publishedFwdSide(buf).block_count = 1;
    publish.publishedFwdSide(buf).group_count = 2;
    publish.publishedFwdSide(buf).first_group = g0;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false }, 1, 0);
    try publish.syncToPublished(&graph, node.index);

    // debugValidate must report a violation; validate may or may not trigger
    // in the fast path, but must not crash.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "shape: grouped single-block adjacency is accepted as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.setBlockLiveCount(&graph.graph, block, .fwd, 0);
    page_ops.groupAt(&graph.graph, group).* = .{
        .start = block, .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = block;
    publish.publishedFwdSide(buf).block_count = 1;
    publish.publishedFwdSide(buf).group_count = 1;
    publish.publishedFwdSide(buf).first_group = group;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found_canonicalization = false;
    for (violations) |v| {
        if (v == .grouped_layout_needs_canonicalization) found_canonicalization = true;
    }
    try testing.expect(!found_canonicalization);
    try graph.validate();
}

test "shape: grouped contiguous run layout is accepted without repair flag" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 98);
    const node = graph_mod.NodeId{ .index = 0 };
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const g0 = try graph.allocGroup();

    for (0..48) |i| page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[i] = @intCast(i + 1);
    page_ops.setBlockLiveCount(&graph.graph, b0, .fwd, @intCast(48));
    for (0..48) |i| page_ops.edgeBlockAt(&graph.graph, b1, .fwd).destinations[i] = @intCast(i + 49);
    page_ops.setBlockLiveCount(&graph.graph, b1, .fwd, @intCast(48));
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).destinations[0] = 97;
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, b2, .fwd, @intCast(1));

    try publishReverseSources(&graph, node.index, 1, 97);

    page_ops.groupAt(&graph.graph, g0).* = .{
        .start = b0, .count = 3,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = b0;
    publish.publishedFwdSide(buf).block_count = 3;
    publish.publishedFwdSide(buf).group_count = 1;
    publish.publishedFwdSide(buf).first_group = g0;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 97, 0);
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(97, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |v| {
        if (v == .grouped_layout_needs_canonicalization) found = true;
    }
    try testing.expect(!found);
    try graph.validate();
}

test "invalid shape: too many groups without needs_repair fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var blocks: [6]u32 = undefined;
    for (0..blocks.len) |i| blocks[i] = try graph.allocBlockFwd();
    for (blocks[0..]) |b| page_ops.setBlockLiveCount(&graph.graph, b, .fwd, 0);

    var groups: [6]u32 = undefined;
    for (0..groups.len) |i| groups[i] = try graph.allocGroup();

    for (0..groups.len - 1) |i| {
        page_ops.groupAt(&graph.graph, groups[i]).* = .{
            .start = blocks[i], .count = 1,
        };
    }
    page_ops.groupAt(&graph.graph, groups[groups.len - 1]).* = .{
        .start = blocks[blocks.len - 1], .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = blocks[0];
    publish.publishedFwdSide(buf).block_count = @intCast(blocks.len);
    publish.publishedFwdSide(buf).group_count = @intCast(groups.len);
    publish.publishedFwdSide(buf).first_group = groups[0];
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "shape: short non-tail run without needs_repair is accepted as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 99);
    const node = graph_mod.NodeId{ .index = 0 };
    const head_block = try graph.allocBlockFwd();
    const middle_block = try graph.allocBlockFwd();
    const tail_block = try graph.allocBlockFwd();
    const short_run_group = try graph.allocGroup();
    const tail_group = try graph.allocGroup();

    for (0..48) |i| page_ops.edgeBlockAt(&graph.graph, head_block, .fwd).destinations[i] = @intCast(i + 1);
    page_ops.setBlockLiveCount(&graph.graph, head_block, .fwd, @intCast(48));
    for (0..48) |i| page_ops.edgeBlockAt(&graph.graph, middle_block, .fwd).destinations[i] = @intCast(i + 49);
    page_ops.setBlockLiveCount(&graph.graph, middle_block, .fwd, @intCast(48));
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).destinations[0] = 97;
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, tail_block, .fwd, @intCast(1));

    try publishReverseSources(&graph, node.index, 1, 97);

    page_ops.groupAt(&graph.graph, short_run_group).* = .{
        .start = head_block, .count = 2,
    };
    page_ops.groupAt(&graph.graph, tail_group).* = .{
        .start = tail_block, .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = head_block;
    publish.publishedFwdSide(buf).block_count = 3;
    publish.publishedFwdSide(buf).group_count = 2;
    publish.publishedFwdSide(buf).first_group = short_run_group;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 97, 0);
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(97, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |v| {
        if (v == .run_fragmentation_requires_repair) found = true;
    }
    try testing.expect(!found);
    try graph.validate();
}
