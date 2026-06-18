const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const testing = std.testing;

fn hasViolationTag(violations: []const types.Violation, comptime tag: std.meta.Tag(types.Violation)) bool {
    for (violations) |violation| {
        if (std.meta.activeTag(violation) == tag) return true;
    }
    return false;
}

fn publishForwardSingleSegment(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_segment: u32,
    block_count: u16,
) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = undefined,
        .block_count = block_count,
        .segment_count = 1,
        .first_segment = first_segment,
    };
    node_buffer.storePublicationState(.{ .needs_repair_fwd = true });
    try publish.syncToPublished(&graph, node.index);
}

test "validation: debugValidate accepts short non-tail segments as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const head_block = try graph.allocBlockFwd();
    const tail_block = try graph.allocBlockFwd();
    const short_segment = try graph.allocSegment();
    const tail_segment = try graph.allocSegment();

    page_ops.setBlockAliveCount(&graph.graph, head_block, .fwd, 0);
    page_ops.setBlockAliveCount(&graph.graph, tail_block, .fwd, 0);

    page_ops.edgeBlockSegmentAt(&graph.graph, short_segment).* = .{
        .start = head_block,
        .count = 2,
    };
    page_ops.edgeBlockSegmentAt(&graph.graph, tail_segment).* = .{
        .start = tail_block,
        .count = 1,
    };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = head_block,
        .block_count = 3,
        .segment_count = 2,
        .first_segment = short_segment,
    };
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!hasViolationTag(violations, .segment_fragmentation_requires_repair));
}

test "validation: debugValidate accepts segmented contiguous single segment layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    const block2 = try graph.allocBlockFwd();
    const segment = try graph.allocSegment();

    page_ops.setBlockAliveCount(&graph.graph, block0, .fwd, 0);
    page_ops.setBlockAliveCount(&graph.graph, block1, .fwd, 0);
    page_ops.setBlockAliveCount(&graph.graph, block2, .fwd, 0);

    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{
        .start = block0,
        .count = 3,
    };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = block0,
        .block_count = 3,
        .segment_count = 1,
        .first_segment = segment,
    };
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!hasViolationTag(violations, .segmented_layout_needs_canonicalization));
}

test "validation: debugValidate emits degree_mismatch when cached degree diverges from alive edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_a = try graph.addNode();
    const target_b = try graph.addNode();

    try graph.addEdge(source, target_a, 0, 0);
    try graph.addEdge(source, target_b, 0, 0);

    var state = page_ops.nodePublicationAtConst(&graph.graph, source).loadPublicationState();
    state.degree_fwd = 0;
    state.degree_rev = 99;
    publish.storePublicationState(&graph, source.index, state);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .degree_mismatch));

    var saw_fwd = false;
    var saw_rev = false;
    for (violations) |violation| {
        if (violation == .degree_mismatch) {
            if (violation.degree_mismatch.expected == 2 and violation.degree_mismatch.actual == 0) {
                try testing.expectEqual(source.index, violation.degree_mismatch.node);
                saw_fwd = true;
            } else if (violation.degree_mismatch.expected == 0 and violation.degree_mismatch.actual == 99) {
                saw_rev = true;
            }
        }
    }
    try testing.expect(saw_fwd);
    try testing.expect(saw_rev);
}

test "validation: debugValidate detects forward/reverse visible count mismatch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source_one = try graph.addNode();
    const destination = try graph.addNode();
    const source_two = try graph.addNode();

    try graph.addEdge(source_one, destination, 0, 0);
    try graph.addEdge(source_two, destination, 0, 0);
    try graph.validate();

    const destination_adj = try graph.publishedNodeAdj(destination);
    if (publish.reverseIsTiny(destination_adj)) {
        try publish.appendReverseSource(&graph, destination, destination_adj, try publish.readReverseSource(&graph, destination_adj, 0));
    } else {
        const rev_block = page_ops.edgeBlockAt(&graph.graph, destination_adj.first_block_rev, .rev);
        const alive: u7 = @intCast(page_ops.blockAliveCount(&graph.graph, destination_adj.first_block_rev, .rev));

        // Duplicate the first source entry to create 3 reverse but only 2 forward.
        if (alive < 64) {
            const dup_source = rev_block.sources[0];
            rev_block.sources[alive] = dup_source;
            page_ops.setBlockAliveCount(&graph.graph, destination_adj.first_block_rev, .rev, @intCast(alive + 1));
        }
    }

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .forward_reverse_count_mismatch));

    for (violations) |violation| {
        if (violation == .forward_reverse_count_mismatch) {
            try testing.expectEqual(@as(u64, 2), violation.forward_reverse_count_mismatch.forward_total);
            try testing.expectEqual(@as(u64, 3), violation.forward_reverse_count_mismatch.reverse_total);
        }
    }
}

test "validation: debugValidate emits forward_tombstone_missing_repair_flag when flag is absent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const removed_destination = try graph.addNode();
    try graph.addEdge(source, removed_destination, 0, 0);

    _ = try graph.removeNode(removed_destination);
    try graph.validate();

    var state = page_ops.nodePublicationAtConst(&graph.graph, source).loadPublicationState();
    state.needs_repair_fwd = false;
    publish.storePublicationState(&graph, source.index, state);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .forward_tombstone_missing_repair_flag));

    for (violations) |violation| {
        if (violation == .forward_tombstone_missing_repair_flag) {
            try testing.expectEqual(source.index, violation.forward_tombstone_missing_repair_flag.node);
        }
    }
}

test "validation: debugValidate catches segment_count longer than actual chain even when block_count matches" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const b0 = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, b0, .fwd, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[0] = 0;

    const g0 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.publishedFwdSide(node_buffer).segment_count = 2;
    publish.publishedFwdSide(node_buffer).first_segment = g0;
    publish.setPublishedFwdDegree(node_buffer, 1);
    try publish.syncToPublished(&graph, node.index);

    // Fast validator: chain length (1) != declared segment_count (2) → CorruptGraph
    try testing.expectError(error.CorruptGraph, graph.validate());

    // Debug validator must also catch this.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
