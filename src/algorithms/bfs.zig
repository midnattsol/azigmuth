const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

/// Returns nodes in breadth-first order starting from `start`.
/// The caller owns the returned slice.
///
/// Concurrent-safe, but not a global snapshot: traversal observes a valid
/// evolving view of the graph while mutations continue.
pub fn bfs(read: *const common.ReadSession, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = read.nodeCount();
    try read.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var queue = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    defer queue.deinit(allocator);
    var order: std.ArrayList(types.NodeId) = .empty;
    errdefer order.deinit(allocator);

    try common.ensureBitCapacity(&visited, allocator, start.index);
    visited.set(start.index);
    try queue.append(allocator, start);
    try order.append(allocator, start);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        var cursor = try read.neighborsCursor(current) orelse continue;
        while (cursor.next()) |neighbor| {
            try common.ensureBitCapacity(&visited, allocator, neighbor.index);
            if (!visited.isSet(neighbor.index)) {
                visited.set(neighbor.index);
                try queue.append(allocator, neighbor);
                try order.append(allocator, neighbor);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}
