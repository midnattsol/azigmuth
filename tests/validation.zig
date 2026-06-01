const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;

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
    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].first_block_fwd = block_index;
    node_buffer.adj_buffers[0].block_count_fwd = block_count;
    node_buffer.storePublishedAdjIndex(0);
}

fn publishForwardGroups(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_group: u32,
    block_count: u16,
    group_count: u16,
) !void {
    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].block_count_fwd = block_count;
    node_buffer.adj_buffers[0].group_count_fwd = group_count;
    node_buffer.adj_buffers[0].first_group_fwd = first_group;
    node_buffer.storePublishedAdjIndex(0);
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
    try graph.graph.free_blocks_fwd.append(graph.graph.allocator, block);

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
    try graph.graph.retired_blocks_fwd.append(graph.graph.allocator, .{ .block = block, .epoch = 0 });

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

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .repair_debt_invalid_node));
}
