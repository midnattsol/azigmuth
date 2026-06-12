const std = @import("std");
const graph_mod = @import("graph_mod");

pub fn expectOutNeighbors(
    graph: *const graph_mod.Graph,
    allocator: std.mem.Allocator,
    node: graph_mod.NodeId,
    expected_idxs: []const u32,
) !void {
    var iterator = try graph.neighbors(node);
    const actual_neighbors = try graph_mod.materializeConsuming(&iterator, allocator);
    defer allocator.free(actual_neighbors);

    try std.testing.expectEqual(expected_idxs.len, actual_neighbors.len);
    for (expected_idxs, actual_neighbors) |expected_idx, actual_neighbor| {
        try std.testing.expectEqual(expected_idx, actual_neighbor.index);
    }
}

pub fn expectInNeighbors(
    graph: *const graph_mod.Graph,
    allocator: std.mem.Allocator,
    node: graph_mod.NodeId,
    expected_idxs: []const u32,
) !void {
    var iterator = try graph.inNeighbors(node);
    const actual_neighbors = try graph_mod.materializeConsuming(&iterator, allocator);
    defer allocator.free(actual_neighbors);

    try std.testing.expectEqual(expected_idxs.len, actual_neighbors.len);
    for (expected_idxs, actual_neighbors) |expected_idx, actual_neighbor| {
        try std.testing.expectEqual(expected_idx, actual_neighbor.index);
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
        const actual_idx: usize = @intCast(actual_neighbor.index);
        try std.testing.expect(actual_idx < total_node_count);
        seen.set(actual_idx);
    }

    for (expected_nodes) |expected_node| {
        const expected_idx: usize = @intCast(expected_node.index);
        try std.testing.expect(seen.isSet(expected_idx));
    }
}

pub fn expectNodeAbsent(actual_neighbors: []const graph_mod.NodeId, absent_node: graph_mod.NodeId) !void {
    for (actual_neighbors) |actual_neighbor| {
        try std.testing.expect(actual_neighbor.index != absent_node.index);
    }
}
