const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");

const StackEntry = struct {
    node: types.NodeId,
    iterator: @import("../query.zig").NeighborIterator,
    entered: bool = false,
};

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

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, node_count);
    defer {
        for (stack.items) |*entry| entry.iterator.deinit();
        stack.deinit(allocator);
    }
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    try common.ensureBitCapacity(&visited, allocator, start.index);
    try stack.append(allocator, .{
        .node = start,
        .iterator = try common.neighborIteratorOrNull(graph, start) orelse return error.InvalidNode,
    });

    while (stack.items.len > 0) {
        const current = &stack.items[stack.items.len - 1];
        if (!current.entered) {
            try common.ensureBitCapacity(&visited, allocator, current.node.index);
            if (visited.isSet(current.node.index)) {
                current.iterator.deinit();
                _ = stack.pop();
                continue;
            }
            visited.set(current.node.index);
            try order.append(allocator, current.node);
            current.entered = true;
        }

        var pushed = false;
        while (current.iterator.next()) |neighbor| {
            try common.ensureBitCapacity(&visited, allocator, neighbor.index);
            if (visited.isSet(neighbor.index)) continue;

            if (try common.neighborIteratorOrNull(graph, neighbor)) |next_iterator| {
                try stack.append(allocator, .{
                    .node = neighbor,
                    .iterator = next_iterator,
                });
                pushed = true;
                break;
            }
        }

        if (!pushed) {
            current.iterator.deinit();
            _ = stack.pop();
        }
    }

    return order.toOwnedSlice(allocator);
}
