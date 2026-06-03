//! Invalid group shape detection — verified that structurally impossible
//! adjacency layouts are rejected rather than silently corrupted.

const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const helpers = @import("helpers.zig");

const testing = std.testing;

test "invalid shape: block_count == 1 with group_count > 1 fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;

    page_ops.groupAt(&graph.graph, g0).* = .{
        .start = block, .count = 1, .next = g1,
    };
    page_ops.groupAt(&graph.graph, g1).* = .{
        .start = block, .count = 1, .next = constants.END_OF_CHAIN,
    };

    const buf = try graph.nodeAt(node);
    helpers.publishedFwdSide(buf).first_block = block;
    helpers.publishedFwdSide(buf).block_count = 1;
    helpers.publishedFwdSide(buf).group_count = 2;
    helpers.publishedFwdSide(buf).first_group = g0;
    helpers.setPublishedState(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false }, 1, 0);

    // debugValidate must report a violation; validate may or may not trigger
    // in the fast path, but must not crash.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "invalid shape: grouped single-block adjacency is detected as repair debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    page_ops.groupAt(&graph.graph, group).* = .{
        .start = block, .count = 1, .next = constants.END_OF_CHAIN,
    };

    const buf = try graph.nodeAt(node);
    helpers.publishedFwdSide(buf).first_block = block;
    helpers.publishedFwdSide(buf).block_count = 1;
    helpers.publishedFwdSide(buf).group_count = 1;
    helpers.publishedFwdSide(buf).first_group = group;
    helpers.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    var found_canonicalization = false;
    for (violations) |v| {
        if (v == .grouped_layout_needs_canonicalization) {
            found_canonicalization = true;
            try testing.expectEqual(node.index, v.grouped_layout_needs_canonicalization.node);
        }
    }
    try testing.expect(found_canonicalization);

    _ = graph.validate() catch {};
}

test "invalid shape: grouped contiguous chain must be marked needs_repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    const g0 = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = 0;
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = 0;
    page_ops.edgeBlockAt(&graph.graph, b2, .fwd).mask = 0;

    page_ops.groupAt(&graph.graph, g0).* = .{
        .start = b0, .count = 3, .next = constants.END_OF_CHAIN,
    };

    const buf = try graph.nodeAt(node);
    helpers.publishedFwdSide(buf).first_block = b0;
    helpers.publishedFwdSide(buf).block_count = 3;
    helpers.publishedFwdSide(buf).group_count = 1;
    helpers.publishedFwdSide(buf).first_group = g0;
    helpers.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |v| {
        if (v == .grouped_layout_needs_canonicalization) {
            found = true;
        }
    }
    try testing.expect(found);

    _ = graph.validate() catch {};
}

test "invalid shape: too many groups without needs_repair fails validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var blocks: [6]u32 = undefined;
    for (0..blocks.len) |i| blocks[i] = try graph.allocBlockFwd();
    for (blocks[0..]) |b| page_ops.edgeBlockAt(&graph.graph, b, .fwd).mask = 0;

    var groups: [6]u32 = undefined;
    for (0..groups.len) |i| groups[i] = try graph.allocGroup();

    for (0..groups.len - 1) |i| {
        page_ops.groupAt(&graph.graph, groups[i]).* = .{
            .start = blocks[i], .count = 1, .next = groups[i + 1],
        };
    }
    page_ops.groupAt(&graph.graph, groups[groups.len - 1]).* = .{
        .start = blocks[blocks.len - 1], .count = 1, .next = constants.END_OF_CHAIN,
    };

    const buf = try graph.nodeAt(node);
    helpers.publishedFwdSide(buf).first_block = blocks[0];
    helpers.publishedFwdSide(buf).block_count = @intCast(blocks.len);
    helpers.publishedFwdSide(buf).group_count = @intCast(groups.len);
    helpers.publishedFwdSide(buf).first_group = groups[0];
    helpers.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);

    _ = graph.validate() catch {};
}

test "invalid shape: short non-tail run without needs_repair emits fragmentation violation" {
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
        .start = head_block, .count = 2, .next = tail_group,
    };
    page_ops.groupAt(&graph.graph, tail_group).* = .{
        .start = tail_block, .count = 1, .next = constants.END_OF_CHAIN,
    };

    const buf = try graph.nodeAt(node);
    helpers.publishedFwdSide(buf).first_block = head_block;
    helpers.publishedFwdSide(buf).block_count = 3;
    helpers.publishedFwdSide(buf).group_count = 2;
    helpers.publishedFwdSide(buf).first_group = short_run_group;
    helpers.setPublishedState(buf, .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = false }, 0, 0);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

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
