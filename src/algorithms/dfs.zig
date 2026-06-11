const std = @import("std");
const context_mod = @import("context.zig");
const snapshot_iterators = @import("../query/snapshot/iterators.zig");
const snapshot_view = @import("../query/snapshot/view.zig");
const types = @import("../core/types.zig");

const DfsFrame = struct {
    node_idx: u32,
    cursor: snapshot_iterators.FrameNeighborCursor,
};

fn initFrameLive(view: *const snapshot_view.CapturedGraphView, node_idx: u32) DfsFrame {
    return .{
        .node_idx = node_idx,
        .cursor = snapshot_iterators.FrameNeighborCursor.init(view, node_idx),
    };
}

/// Returns nodes in depth-first order starting from `start` over a fixed
/// captured graph view. Honors `ctx.cancel_token` cooperatively: cancellation
/// is observed once per stack step and aborts with `error.Cancelled`.
pub fn dfsCaptured(view: *const snapshot_view.CapturedGraphView, start: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
    const allocator = ctx.allocator;
    const node_count = view.nodeCount();
    try view.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(DfsFrame).initCapacity(allocator, node_count);
    defer stack.deinit(allocator);
    var order = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    errdefer order.deinit(allocator);

    visited.set(start.index);
    order.appendAssumeCapacity(start);
    if (view.degree_fwd[start.index] != 0) {
        stack.appendAssumeCapacity(initFrameLive(view, start.index));
    }

    while (stack.items.len > 0) {
        if (ctx.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        const current = &stack.items[stack.items.len - 1];

        var pushed = false;
        while (current.cursor.next(view)) |neighbor_idx| {
            if (visited.isSet(neighbor_idx)) continue;

            visited.set(neighbor_idx);
            order.appendAssumeCapacity(.{ .index = neighbor_idx });
            if (view.degree_fwd[neighbor_idx] != 0) {
                if (view.degree_fwd[current.node_idx] == 1) {
                    current.* = initFrameLive(view, neighbor_idx);
                } else {
                    stack.appendAssumeCapacity(initFrameLive(view, neighbor_idx));
                }
            }
            pushed = true;
            break;
        }

        if (!pushed) {
            _ = stack.pop();
        }
    }

    return order.toOwnedSlice(allocator);
}
