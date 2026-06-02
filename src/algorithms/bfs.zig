const std = @import("std");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const query = @import("../query.zig");
const node_validity = @import("../node_validity.zig");

/// Returns nodes in breadth-first order starting from `start`.
/// The caller owns the returned slice.
pub fn bfs(graph: *const graph_core.GraphCore, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = graph.publishedNodeCount();
    try node_validity.ensureLiveNode(graph, start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var queue = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    defer queue.deinit(allocator);
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    visited.set(start.index);
    try queue.append(allocator, start);
    try order.append(allocator, start);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        var iter = try query.neighbors(graph, current);
        defer iter.deinit();
        while (iter.next()) |neighbor| {
            if (!visited.isSet(neighbor.index)) {
                visited.set(neighbor.index);
                try queue.append(allocator, neighbor);
                try order.append(allocator, neighbor);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}
