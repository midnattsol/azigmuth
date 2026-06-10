const std = @import("std");
const snapshot_iterators = @import("../query/snapshot/iterators.zig");
const snapshot_view = @import("../query/snapshot/view.zig");
const types = @import("../core/types.zig");

const DfsFrame = struct {
    node_idx: u32,
    cursor: snapshot_iterators.SnapshotNeighborIterator,
};

fn initFrameLive(view: *const snapshot_view.CapturedGraphView, node_idx: u32) DfsFrame {
    return .{
        .node_idx = node_idx,
        .cursor = snapshot_iterators.neighborsCursor(view, .{ .index = node_idx }) catch unreachable orelse unreachable,
    };
}

/// Returns nodes in depth-first order starting from `start` over a fixed
/// captured graph view.
pub fn dfsCaptured(view: *const snapshot_view.CapturedGraphView, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
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
        const current = &stack.items[stack.items.len - 1];

        var pushed = false;
        while (current.cursor.next()) |neighbor| {
            if (visited.isSet(neighbor.index)) continue;

            visited.set(neighbor.index);
            order.appendAssumeCapacity(neighbor);
            if (view.degree_fwd[neighbor.index] != 0) {
                if (view.degree_fwd[current.node_idx] == 1) {
                    current.* = initFrameLive(view, neighbor.index);
                } else {
                    stack.appendAssumeCapacity(initFrameLive(view, neighbor.index));
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
