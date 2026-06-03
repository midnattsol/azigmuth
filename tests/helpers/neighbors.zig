const std = @import("std");
const graph_mod = @import("graph_mod");

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
