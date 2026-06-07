const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

const StackEntry = struct {
    node: types.NodeId,
    cursor: common.NeighborsCursor,
    entered: bool = false,
};

/// Returns nodes in depth-first order starting from `start`.
/// The caller owns the returned slice.
///
/// Concurrent-safe, but not a global snapshot: traversal observes a valid
/// evolving view of the graph while mutations continue.
pub fn dfs(read: *const common.ReadSession, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = read.nodeCount();
    try read.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, node_count);
    defer stack.deinit(allocator);
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    try common.ensureBitCapacity(&visited, allocator, start.index);
    try stack.append(allocator, .{
        .node = start,
        .cursor = (try read.neighborsCursor(start)) orelse return error.InvalidNode,
    });

    while (stack.items.len > 0) {
        const current = &stack.items[stack.items.len - 1];
        if (!current.entered) {
            try common.ensureBitCapacity(&visited, allocator, current.node.index);
            if (visited.isSet(current.node.index)) {
                _ = stack.pop();
                continue;
            }
            visited.set(current.node.index);
            try order.append(allocator, current.node);
            current.entered = true;
        }

        var pushed = false;
        while (current.cursor.next()) |neighbor| {
            try common.ensureBitCapacity(&visited, allocator, neighbor.index);
            if (visited.isSet(neighbor.index)) continue;

            if (try read.neighborsCursor(neighbor)) |next_cursor| {
                try stack.append(allocator, .{
                    .node = neighbor,
                    .cursor = next_cursor,
                });
                pushed = true;
                break;
            }
        }

        if (!pushed) {
            _ = stack.pop();
        }
    }

    return order.toOwnedSlice(allocator);
}
