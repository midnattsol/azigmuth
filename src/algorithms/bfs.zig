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

    const Expand = struct {
        visited: *std.DynamicBitSetUnmanaged,
        queue: *std.ArrayList(types.NodeId),

        fn onNeighbor(self: *@This(), neighbor_idx: u32) !void {
            if (self.visited.isSet(neighbor_idx)) return;
            self.visited.set(neighbor_idx);
            // Dedup bounds the queue by node_count, reserved up front.
            self.queue.appendAssumeCapacity(.{ .index = neighbor_idx });
        }
    };
    var expand = Expand{ .visited = &visited, .queue = &queue };

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        if (ctx.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        const current = queue.items[head];
        if (!view.isLiveIndex(current.index)) continue;
        try snapshot_iterators.forEachNeighborInView(view, current.index, &expand, Expand.onNeighbor);
    }

    return queue.toOwnedSlice(allocator);
}
