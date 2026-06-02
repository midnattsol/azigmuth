const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;
const helpers = @import("helpers.zig");

const testing = std.testing;

fn containsViolation(violations: []const types.Violation, comptime tag: std.meta.Tag(types.Violation)) bool {
    for (violations) |violation| {
        if (std.meta.activeTag(violation) == tag) return true;
    }
    return false;
}

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn publishForwardBlock(graph: *graph_mod.Graph, node: graph_mod.NodeId, block_index: u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).first_block = block_index;
    helpers.publishedFwdSide(node_buffer).block_count = block_count;
}

fn publishForwardGroups(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_group: u32,
    block_count: u16,
    group_count: u16,
) !void {
    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = block_count;
    helpers.publishedFwdSide(node_buffer).group_count = group_count;
    helpers.publishedFwdSide(node_buffer).first_group = first_group;
}

test "validation: detects non-dense masks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const target = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.edges[2] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = 0b101;
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .mask_bit_out_of_range));
}

test "validation: detects invalid destinations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = 999, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = constants.denseMask(1);
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .invalid_dst));
}

test "validation: detects unsorted blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 3);
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = 2, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.edges[1] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = constants.denseMask(2);
    try publishForwardBlock(&graph, .{ .index = 0 }, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .unsorted_block));
}

test "validation: detects global edge count mismatch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = [_]graph_mod.NodeId{ try graph.addNode(), try graph.addNode() };
    try graph.addEdge(nodes[0], nodes[1], 0, 0);
    graph.graph.edge_count.store(7, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .edge_count_mismatch));
}

test "validation: detects underfull non-tail blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 60);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();

    var first_edges = page_ops.edgeBlockAt(&graph.graph, first_block, .fwd);
    for (0..47) |edge_index| {
        first_edges.edges[edge_index] = .{ .destination = @intCast(edge_index + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_edges.mask = constants.denseMask(47);

    var second_edges = page_ops.edgeBlockAt(&graph.graph, second_block, .fwd);
    second_edges.edges[0] = .{ .destination = 48, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    second_edges.mask = constants.denseMask(1);

    try publishForwardBlock(&graph, .{ .index = 0 }, first_block, 2);
    graph.graph.edge_count.store(48, .release);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .occupancy_below_threshold));
}

test "validation: detects block group cycles without hanging" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = group };
    try publishForwardGroups(&graph, node, group, 1, 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_chain_cycle));
}

test "validation: detects overlapping block groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const group0 = try graph.allocGroup();
    const group1 = try graph.allocGroup();

    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 2, .next = group1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block0 + 1, .count = 1, .next = constants.END_OF_CHAIN };
    try publishForwardGroups(&graph, node, group0, 3, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_overlap));
}

test "validation: detects double-owned blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node0 = try graph.addNode();
    const node1 = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;

    try publishForwardBlock(&graph, node0, block, 1);
    try publishForwardBlock(&graph, node1, block, 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_double_owned));
}

test "validation: detects owned blocks present in free list" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    try publishForwardBlock(&graph, node, block, 1);
    page_ops.freeBlock(&graph.graph, block, .fwd);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_orphaned_in_free_list));
}

test "validation: detects retired blocks still reachable" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    try publishForwardBlock(&graph, node, block, 1);
    try graph.retireBlockFwd(block);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .retired_block_reachable));
}

test "validation: detects invalid repair debt entries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    try graph.graph.repair_fwd.append(graph.graph.allocator, 123);
    try graph.graph.repair_rev.append(graph.graph.allocator, 456);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .repair_debt_invalid_node));
}

test "validation: grouped block_count mismatch vs sum of group.count is detected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 5);

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    fillBlockWithDst(&graph, b0, 1, 1);
    fillBlockWithDst(&graph, b1, 2, 1);

    const g0 = try graph.allocGroup();
    // Single group covering 2 physically contiguous blocks.
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 2, .next = constants.END_OF_CHAIN };

    // Reverse adjacency for both destinations so forward/reverse consistency passes.
    const rb0 = try graph.allocBlockRev();
    const rb1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, rb0, .rev).sources[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, rb0, .rev).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, rb1, .rev).sources[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, rb1, .rev).mask = constants.denseMask(1);
    {
        const d1 = try graph.nodeAt(.{ .index = 1 });
        helpers.clearPublishedSides(d1);
        helpers.publishedRevSide(d1).first_block = rb0;
        helpers.publishedRevSide(d1).block_count = 1;
        d1.degree_rev = 1;
    }
    {
        const d2 = try graph.nodeAt(.{ .index = 2 });
        helpers.clearPublishedSides(d2);
        helpers.publishedRevSide(d2).first_block = rb1;
        helpers.publishedRevSide(d2).block_count = 1;
        d2.degree_rev = 1;
    }

    const node = try graph.nodeAt(.{ .index = 0 });
    helpers.clearPublishedSides(node);
    // block_count says 1, but the chain spans 2 blocks.
    helpers.publishedFwdSide(node).first_block = b0;
    helpers.publishedFwdSide(node).block_count = 1;
    helpers.publishedFwdSide(node).group_count = 1;
    helpers.publishedFwdSide(node).first_group = g0;
    node.degree_fwd = 2;
    graph.graph.edge_count.store(2, .release);

    // validate() must now detect this mismatch.
    try testing.expectError(error.CorruptGraph, graph.validate());
}

fn fillBlockWithDst(graph: *graph_mod.Graph, block_index: u32, first_dst: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |i| {
        block.edges[i] = .{ .destination = first_dst + @as(u32, @intCast(i)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
}

test "validation: removed node entry in repair queue is currently accepted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    try graph.removeNode(target);

    try graph.graph.repair_fwd.append(graph.graph.allocator, target.index);

    // Current semantics: validate does not reject in-range-but-removed queue entries.
    try graph.validate();

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(!containsViolation(violations, .repair_debt_invalid_node));
}

test "validation: detects degree cache mismatch in fast validate" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    var node = try graph.nodeAt(source);
    node.degree_fwd = 7;

    try testing.expectError(error.CorruptGraph, graph.validate());
}
