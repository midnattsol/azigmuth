const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;
const helpers = @import("helpers.zig");

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
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).* = .{
        .first_block = undefined,
        .block_count = block_count,
        .group_count = 1,
        .first_group = first_group,
    };
    node_buffer.storePublishedMeta(.{ .needs_repair_fwd = true });
}

test "validation: debugValidate emits run_fragmentation_requires_repair for short non-tail runs" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const head_block = try graph.allocBlockFwd();
    const tail_block = try graph.allocBlockFwd();
    const short_run_group = try graph.allocGroup();
    const tail_group = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, head_block, .fwd).mask = 0;
    page_ops.edgeBlockAt(&graph.graph, tail_block, .fwd).mask = 0;

    page_ops.groupAt(&graph.graph, short_run_group).* = .{
        .start = head_block,
        .count = 2,
        .next = tail_group,
    };
    page_ops.groupAt(&graph.graph, tail_group).* = .{
        .start = tail_block,
        .count = 1,
        .next = constants.END_OF_CHAIN,
    };

    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).* = .{
        .first_block = head_block,
        .block_count = 3,
        .group_count = 2,
        .first_group = short_run_group,
    };

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .run_fragmentation_requires_repair));

    var found = false;
    for (violations) |v| {
        if (v == .run_fragmentation_requires_repair) {
            try testing.expectEqual(node.index, v.run_fragmentation_requires_repair.node);
            try testing.expectEqual(short_run_group, v.run_fragmentation_requires_repair.group);
            try testing.expect(v.run_fragmentation_requires_repair.count < 4);
            found = true;
        }
    }
    try testing.expect(found);
}

test "validation: debugValidate emits grouped_layout_needs_canonicalization for contiguous single group" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    const block2 = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, block0, .fwd).mask = 0;
    page_ops.edgeBlockAt(&graph.graph, block1, .fwd).mask = 0;
    page_ops.edgeBlockAt(&graph.graph, block2, .fwd).mask = 0;

    page_ops.groupAt(&graph.graph, group).* = .{
        .start = block0,
        .count = 3,
        .next = constants.END_OF_CHAIN,
    };

    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).* = .{
        .first_block = block0,
        .block_count = 3,
        .group_count = 1,
        .first_group = group,
    };

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .grouped_layout_needs_canonicalization));

    for (violations) |v| {
        if (v == .grouped_layout_needs_canonicalization) {
            try testing.expectEqual(node.index, v.grouped_layout_needs_canonicalization.node);
            try testing.expectEqual(group, v.grouped_layout_needs_canonicalization.first_group);
        }
    }
}

test "validation: debugValidate emits degree_mismatch when cached degree diverges from live edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_a = try graph.addNode();
    const target_b = try graph.addNode();

    try graph.addEdge(source, target_a, 0, 0);
    try graph.addEdge(source, target_b, 0, 0);

    const node_buffer = try graph.nodeAt(source);
    helpers.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(0)));
    helpers.setPublishedRevDegree(node_buffer, @as(u22, @intCast(99)));

    const violations = try graph.debugValidate(testing.allocator);
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

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();
    const rev_block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
    const live: u7 = @intCast(@popCount(rev_block.mask));

    // Duplicate the first source entry to create 3 reverse but only 2 forward.
    if (live < 64) {
        const dup_source = rev_block.sources[0];
        rev_block.sources[live] = dup_source;
        rev_block.mask = constants.denseMask(@intCast(live + 1));
    }

    const violations = try graph.debugValidate(testing.allocator);
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

    try graph.removeNode(b);
    try graph.validate();

    const a_node = try graph.nodeAt(a);
    {
        var flags = a_node.loadPublishedMeta().flags();
        flags.needs_repair_fwd = false;
        helpers.setPublishedFlags(a_node, flags);
    }

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(hasViolationTag(violations, .forward_tombstone_missing_repair_flag));

    for (violations) |v| {
        if (v == .forward_tombstone_missing_repair_flag) {
            try testing.expectEqual(a.index, v.forward_tombstone_missing_repair_flag.node);
        }
    }
}
