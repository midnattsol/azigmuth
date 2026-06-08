const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

/// Returns nodes in breadth-first order starting from `start` over a fixed
/// captured graph view.
pub fn bfsCaptured(view: *const common.CapturedGraphView, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = view.nodeCount();
    try view.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var queue = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    errdefer queue.deinit(allocator);

    visited.set(start.index);
    try queue.append(allocator, start);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        var cursor = try view.neighborsCursor(current) orelse continue;
        while (cursor.next()) |neighbor| {
            if (!visited.isSet(neighbor.index)) {
                visited.set(neighbor.index);
                try queue.append(allocator, neighbor);
            }
        }
    }

    return queue.toOwnedSlice(allocator);
}
