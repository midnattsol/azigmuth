const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

const CapturedStackEntry = struct {
    node: types.NodeId,
    cursor: common.SnapshotNeighborIterator,
};

/// Returns nodes in depth-first order starting from `start` over a fixed
/// captured graph view.
pub fn dfsCaptured(view: *const common.CapturedGraphView, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = view.nodeCount();
    try view.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(CapturedStackEntry).initCapacity(allocator, node_count);
    defer stack.deinit(allocator);
    var order = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    errdefer order.deinit(allocator);

    visited.set(start.index);
    try order.append(allocator, start);
    try stack.append(allocator, .{
        .node = start,
        .cursor = (try view.neighborsCursor(start)) orelse return error.InvalidNode,
    });

    while (stack.items.len > 0) {
        const current = &stack.items[stack.items.len - 1];

        var pushed = false;
        while (current.cursor.next()) |neighbor| {
            if (visited.isSet(neighbor.index)) continue;

            if (try view.neighborsCursor(neighbor)) |next_cursor| {
                visited.set(neighbor.index);
                try order.append(allocator, neighbor);
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
