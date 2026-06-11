const std = @import("std");
const context_mod = @import("context.zig");
const snapshot_iterators = @import("../query/snapshot/iterators.zig");
const snapshot_view = @import("../query/snapshot/view.zig");
const types = @import("../core/types.zig");

/// Returns nodes in breadth-first order starting from `start` over a fixed
/// captured graph view. Honors `ctx.cancel_token` cooperatively: cancellation
/// is observed once per expanded node and aborts with `error.Cancelled`.
pub fn bfsCaptured(view: *const snapshot_view.CapturedGraphView, start: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
    const allocator = ctx.allocator;
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
        if (ctx.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        const current = queue.items[head];
        var cursor = try snapshot_iterators.neighborsCursor(view, current) orelse continue;
        while (cursor.next()) |neighbor| {
            if (!visited.isSet(neighbor.index)) {
                visited.set(neighbor.index);
                try queue.append(allocator, neighbor);
            }
        }
    }

    return queue.toOwnedSlice(allocator);
}
