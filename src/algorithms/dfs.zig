const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");

/// Returns nodes in depth-first order starting from `start`.
/// The caller owns the returned slice.
///
/// Concurrent-safe, but not a global snapshot: traversal observes a valid
/// evolving view of the graph while mutations continue.
pub fn dfs(graph: *const graph_core.GraphCore, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = graph.publishedNodeCount();
    try node_validity.ensureLiveNode(graph, start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    defer stack.deinit(allocator);
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    try common.ensureBitCapacity(&visited, allocator, start.index);
    try stack.append(allocator, start);

    while (stack.items.len > 0) {
        const current = stack.pop().?;
        try common.ensureBitCapacity(&visited, allocator, current.index);
        if (visited.isSet(current.index)) continue;

        visited.set(current.index);
        try order.append(allocator, current);

        const neighbors = try common.materializeNeighborsOrEmpty(graph, current, allocator);
        defer allocator.free(neighbors);

        var neighbor_idx = neighbors.len;
        while (neighbor_idx > 0) {
            neighbor_idx -= 1;
            const neighbor = neighbors[neighbor_idx];
            try common.ensureBitCapacity(&visited, allocator, neighbor.index);
            if (!visited.isSet(neighbor.index)) {
                try stack.append(allocator, neighbor);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}
