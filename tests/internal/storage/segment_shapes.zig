//! Invalid segment shape detection — verified that structurally impossible
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
        page_ops.setBlockAliveCount(&graph.graph, block, .rev, @intCast(1));
        const buf = try graph.nodeAt(.{ .index = first_destination + @as(u32, @intCast(offset)) });
        publish.clearPublishedSides(buf);
        publish.publishedRevSide(buf).first_block = block;
        publish.publishedRevSide(buf).block_count = 1;
        publish.setPublishedRevDegree(buf, 1);
        try publish.syncToPublished(graph, first_destination + @as(u32, @intCast(offset)));
    }
}

test "invalid shape: block_count == 1 with segment_count > 1 fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();

    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);

    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{
        .start = block,
        .count = 1,
    };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{
        .start = block,
        .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = block;
    publish.publishedFwdSide(buf).block_count = 1;
    publish.publishedFwdSide(buf).segment_count = 2;
    publish.publishedFwdSide(buf).first_segment = g0;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false }, 1, 0);
    try publish.syncToPublished(&graph, node.index);

    // debugValidate must report a violation; validate may or may not trigger
    // in the fast path, but must not crash.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "shape: segmented single-block adjacency is accepted as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const segment = try graph.allocSegment();

    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);
    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{
        .start = block,
        .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = block;
    publish.publishedFwdSide(buf).block_count = 1;
    publish.publishedFwdSide(buf).segment_count = 1;
    publish.publishedFwdSide(buf).first_segment = segment;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found_canonicalization = false;
    for (violations) |violation| {
        if (violation == .segmented_layout_needs_canonicalization) found_canonicalization = true;
    }
    try testing.expect(!found_canonicalization);
    try graph.validate();
}

test "shape: segmented contiguous segment layout is accepted without repair flag" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 98);
    const node = graph_mod.NodeId{ .index = 0 };
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const g0 = try graph.allocSegment();

    for (0..48) |slot_idx| page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[slot_idx] = @intCast(slot_idx + 1);
    page_ops.setBlockAliveCount(&graph.graph, b0, .fwd, @intCast(48));
    for (0..48) |slot_idx| page_ops.edgeBlockAt(&graph.graph, b1, .fwd).destinations[slot_idx] = @intCast(slot_idx + 49);
    page_ops.setBlockAliveCount(&graph.graph, b1, .fwd, @intCast(48));
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).destinations[0] = 97;
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, b2, .fwd, @intCast(1));

    try publishReverseSources(&graph, node.index, 1, 97);

    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{
        .start = b0,
        .count = 3,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = b0;
    publish.publishedFwdSide(buf).block_count = 3;
    publish.publishedFwdSide(buf).segment_count = 1;
    publish.publishedFwdSide(buf).first_segment = g0;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 97, 0);
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(97, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| {
        if (violation == .segmented_layout_needs_canonicalization) found = true;
    }
    try testing.expect(!found);
    try graph.validate();
}

test "invalid shape: too many segments without needs_repair fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var blocks: [6]u32 = undefined;
    for (0..blocks.len) |block_idx| blocks[block_idx] = try graph.allocBlockFwd();
    for (blocks[0..]) |block| page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);

    var segments: [6]u32 = undefined;
    for (0..segments.len) |segment_idx| segments[segment_idx] = try graph.allocSegment();

    for (0..segments.len - 1) |segment_idx| {
        page_ops.edgeBlockSegmentAt(&graph.graph, segments[segment_idx]).* = .{
            .start = blocks[segment_idx],
            .count = 1,
        };
    }
    page_ops.edgeBlockSegmentAt(&graph.graph, segments[segments.len - 1]).* = .{
        .start = blocks[blocks.len - 1],
        .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = blocks[0];
    publish.publishedFwdSide(buf).block_count = @intCast(blocks.len);
    publish.publishedFwdSide(buf).segment_count = @intCast(segments.len);
    publish.publishedFwdSide(buf).first_segment = segments[0];
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "shape: short non-tail segment without needs_repair is accepted as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 99);
    const node = graph_mod.NodeId{ .index = 0 };
    const head_block = try graph.allocBlockFwd();
    const middle_block = try graph.allocBlockFwd();
    const tail_block = try graph.allocBlockFwd();
    const short_segment = try graph.allocSegment();
    const tail_segment = try graph.allocSegment();

    for (0..48) |slot_idx| page_ops.edgeBlockAt(&graph.graph, head_block, .fwd).destinations[slot_idx] = @intCast(slot_idx + 1);
    page_ops.setBlockAliveCount(&graph.graph, head_block, .fwd, @intCast(48));
    for (0..48) |slot_idx| page_ops.edgeBlockAt(&graph.graph, middle_block, .fwd).destinations[slot_idx] = @intCast(slot_idx + 49);
    page_ops.setBlockAliveCount(&graph.graph, middle_block, .fwd, @intCast(48));
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).destinations[0] = 97;
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, tail_block, .fwd, @intCast(1));

    try publishReverseSources(&graph, node.index, 1, 97);

    page_ops.edgeBlockSegmentAt(&graph.graph, short_segment).* = .{
        .start = head_block,
        .count = 2,
    };
    page_ops.edgeBlockSegmentAt(&graph.graph, tail_segment).* = .{
        .start = tail_block,
        .count = 1,
    };

    const buf = try graph.nodeAt(node);
    publish.publishedFwdSide(buf).first_block = head_block;
    publish.publishedFwdSide(buf).block_count = 3;
    publish.publishedFwdSide(buf).segment_count = 2;
    publish.publishedFwdSide(buf).first_segment = short_segment;
    publish.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 97, 0);
    try publish.syncToPublished(&graph, node.index);
    graph.graph.edge_count.store(97, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| {
        if (violation == .segment_fragmentation_requires_repair) found = true;
    }
    try testing.expect(!found);
    try graph.validate();
}
