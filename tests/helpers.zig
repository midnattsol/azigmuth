const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const types = test_internals.types;

pub fn clearPublishedSides(node: *graph_mod.NodeBuffer) void {
    node.fwd_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.fwd_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.storePublishedMeta(.{});
}

pub fn publishedFwdSide(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return &node.fwd_buffers[node.loadPublishedMeta().fwd_index];
}

pub fn publishedRevSide(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return &node.rev_buffers[node.loadPublishedMeta().rev_index];
}

pub fn setPublishedAdjSnapshot(node: *graph_mod.NodeBuffer, adj: types.NodeAdj) void {
    const fwd = publishedFwdSide(node);
    fwd.* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    const rev = publishedRevSide(node);
    rev.* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    node.storePublishedMeta((types.PublishedMeta{}).withFlags(adj.flags));
}

pub fn setPublishedFlags(node: *graph_mod.NodeBuffer, flags: types.NodeFlags) void {
    const meta = node.loadPublishedMeta();
    node.storePublishedMeta(meta.withFlags(flags));
}

pub fn updatePublishedFlags(node: *graph_mod.NodeBuffer, update: fn (*types.NodeFlags) void) void {
    var flags = node.loadPublishedMeta().flags();
    update(&flags);
    setPublishedFlags(node, flags);
}

pub fn addNodes(graph: *graph_mod.Graph, comptime node_count: usize) ![node_count]graph_mod.NodeId {
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |node_index| {
        nodes[node_index] = try graph.addNode();
    }
    return nodes;
}

pub fn expectOutNeighbors(
    graph: *const graph_mod.Graph,
    allocator: std.mem.Allocator,
    node: graph_mod.NodeId,
    expected_indexes: []const u32,
) !void {
    var iterator = try graph.neighbors(node);
    const actual_neighbors = try iterator.materialize(allocator);
    defer allocator.free(actual_neighbors);

    try std.testing.expectEqual(expected_indexes.len, actual_neighbors.len);
    for (expected_indexes, actual_neighbors) |expected_index, actual_neighbor| {
        try std.testing.expectEqual(expected_index, actual_neighbor.index);
    }
}

pub fn expectInNeighbors(
    graph: *const graph_mod.Graph,
    allocator: std.mem.Allocator,
    node: graph_mod.NodeId,
    expected_indexes: []const u32,
) !void {
    var iterator = try graph.inNeighbors(node);
    const actual_neighbors = try iterator.materialize(allocator);
    defer allocator.free(actual_neighbors);

    try std.testing.expectEqual(expected_indexes.len, actual_neighbors.len);
    for (expected_indexes, actual_neighbors) |expected_index, actual_neighbor| {
        try std.testing.expectEqual(expected_index, actual_neighbor.index);
    }
}

pub fn expectNeighborSet(
    actual_neighbors: []const graph_mod.NodeId,
    expected_nodes: []const graph_mod.NodeId,
    total_node_count: usize,
    allocator: std.mem.Allocator,
) !void {
    try std.testing.expectEqual(expected_nodes.len, actual_neighbors.len);

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, total_node_count);
    defer seen.deinit(allocator);

    for (actual_neighbors) |actual_neighbor| {
        const actual_index: usize = @intCast(actual_neighbor.index);
        try std.testing.expect(actual_index < total_node_count);
        seen.set(actual_index);
    }

    for (expected_nodes) |expected_node| {
        const expected_index: usize = @intCast(expected_node.index);
        try std.testing.expect(seen.isSet(expected_index));
    }
}

pub fn expectNodeAbsent(actual_neighbors: []const graph_mod.NodeId, absent_node: graph_mod.NodeId) !void {
    for (actual_neighbors) |actual_neighbor| {
        try std.testing.expect(actual_neighbor.index != absent_node.index);
    }
}
