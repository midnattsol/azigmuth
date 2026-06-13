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

fn publishForwardSingleGroup(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_group: u32,
    block_count: u16,
) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = undefined,
        .block_count = block_count,
        .group_count = 1,
        .first_group = first_group,
    };
    node_buffer.storePublishedMeta(.{ .needs_repair_fwd = true });
    try publish.syncToPublished(&graph, node.index);
}

test "validation: debugValidate accepts short non-tail runs as valid layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const head_block = try graph.allocBlockFwd();
    const tail_block = try graph.allocBlockFwd();
    const short_run_group = try graph.allocGroup();
    const tail_group = try graph.allocGroup();

    page_ops.setBlockLiveCount(&graph.graph, head_block, .fwd, 0);
    page_ops.setBlockLiveCount(&graph.graph, tail_block, .fwd, 0);

    page_ops.edgeBlockGroupAt(&graph.graph, short_run_group).* = .{
        .start = head_block,
        .count = 2,
    };
    page_ops.edgeBlockGroupAt(&graph.graph, tail_group).* = .{
        .start = tail_block,
        .count = 1,
    };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = head_block,
        .block_count = 3,
        .group_count = 2,
        .first_group = short_run_group,
    };
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!hasViolationTag(violations, .run_fragmentation_requires_repair));
}

test "validation: debugValidate accepts grouped contiguous single run layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    const block2 = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.setBlockLiveCount(&graph.graph, block0, .fwd, 0);
    page_ops.setBlockLiveCount(&graph.graph, block1, .fwd, 0);
    page_ops.setBlockLiveCount(&graph.graph, block2, .fwd, 0);

    page_ops.edgeBlockGroupAt(&graph.graph, group).* = .{
        .start = block0,
        .count = 3,
    };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).* = .{
        .first_block = block0,
        .block_count = 3,
        .group_count = 1,
        .first_group = group,
    };
    try publish.syncToPublished(&graph, node.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!hasViolationTag(violations, .grouped_layout_needs_canonicalization));
}

test "validation: debugValidate emits degree_mismatch when cached degree diverges from live edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_a = try graph.addNode();
    const target_b = try graph.addNode();

    try graph.addEdge(source, target_a, 0, 0);
    try graph.addEdge(source, target_b, 0, 0);

    var meta = page_ops.nodeMetaAtConst(&graph.graph, source).loadPublishedMeta();
    meta.degree_fwd = 0;
    meta.degree_rev = 99;
    publish.storePublishedMeta(&graph, source.index, meta);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .degree_mismatch));

    var saw_fwd = false;
    var saw_rev = false;
    for (violations) |v| {
        if (v == .degree_mismatch) {
            if (v.degree_mismatch.expected == 2 and v.degree_mismatch.actual == 0) {
                try testing.expectEqual(source.index, v.degree_mismatch.node);
                saw_fwd = true;
            } else if (v.degree_mismatch.expected == 0 and v.degree_mismatch.actual == 99) {
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

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, b, 0, 0);
    try graph.validate();

    const b_adj = try graph.publishedNodeAdj(b);
    if (publish.reverseIsTiny(b_adj)) {
        try publish.appendReverseSource(&graph, b, b_adj, try publish.readReverseSource(&graph, b_adj, 0));
    } else {
        const rev_block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live: u7 = @intCast(page_ops.blockLiveCount(&graph.graph, b_adj.first_block_rev, .rev));

        // Duplicate the first source entry to create 3 reverse but only 2 forward.
        if (live < 64) {
            const dup_source = rev_block.sources[0];
            rev_block.sources[live] = dup_source;
            page_ops.setBlockLiveCount(&graph.graph, b_adj.first_block_rev, .rev, @intCast(live + 1));
        }
    }

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .forward_reverse_count_mismatch));

    for (violations) |v| {
        if (v == .forward_reverse_count_mismatch) {
            try testing.expectEqual(@as(u64, 2), v.forward_reverse_count_mismatch.forward_total);
            try testing.expectEqual(@as(u64, 3), v.forward_reverse_count_mismatch.reverse_total);
        }
    }
}

test "validation: debugValidate emits forward_tombstone_missing_repair_flag when flag is absent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    _ = try graph.removeNode(b);
    try graph.validate();

    var meta = page_ops.nodeMetaAtConst(&graph.graph, a).loadPublishedMeta();
    meta.needs_repair_fwd = false;
    publish.storePublishedMeta(&graph, a.index, meta);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .forward_tombstone_missing_repair_flag));

    for (violations) |v| {
        if (v == .forward_tombstone_missing_repair_flag) {
            try testing.expectEqual(a.index, v.forward_tombstone_missing_repair_flag.node);
        }
    }
}

test "validation: debugValidate catches group_count longer than actual chain even when block_count matches" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const b0 = try graph.allocBlockFwd();
    page_ops.setBlockLiveCount(&graph.graph, b0, .fwd, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).destinations[0] = 0;

    const g0 = try graph.allocGroup();
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1 };

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = 1;
    publish.publishedFwdSide(node_buffer).group_count = 2;
    publish.publishedFwdSide(node_buffer).first_group = g0;
    publish.setPublishedFwdDegree(node_buffer, 1);
    try publish.syncToPublished(&graph, node.index);

    // Fast validator: chain length (1) != declared group_count (2) → CorruptGraph
    try testing.expectError(error.CorruptGraph, graph.validate());

    // Debug validator must also catch this.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
