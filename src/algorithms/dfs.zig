const std = @import("std");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const query = @import("../query.zig");

/// Returns nodes in depth-first order starting from `start`.
/// The caller owns the returned slice.
pub fn dfs(graph: *const graph_core.GraphCore, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    if (start.index >= graph.node_count) return error.InvalidNode;

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, graph.node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(types.NodeId).initCapacity(allocator, graph.node_count);
    defer stack.deinit(allocator);
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    visited.set(start.index);
    try stack.append(allocator, start);
    try order.append(allocator, start);

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        var iter = try query.neighbors(graph, current);
        defer iter.deinit();
        while (iter.next()) |neighbor| {
            if (!visited.isSet(neighbor.index)) {
                visited.set(neighbor.index);
                try stack.append(allocator, neighbor);
                try order.append(allocator, neighbor);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}
