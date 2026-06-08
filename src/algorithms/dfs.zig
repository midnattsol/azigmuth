const std = @import("std");
const iterator_common = @import("../iterator_common.zig");
const page_ops = @import("../storage/page_ops.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");

const DfsFrame = struct {
    current_block_index: u32,
    blocks_remaining: u16,
    next_group_index: u32,
    groups_remaining: u16,

    current_mask: u64,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,

    check_removed_candidates: bool,

    fn advanceToNextGroup(self: *DfsFrame, view: *const common.CapturedGraphView) bool {
        if (self.groups_remaining == 0) return false;
        const group = page_ops.groupAtConst(view.core, self.next_group_index);
        self.current_block_index = group.start;
        self.blocks_remaining = group.count;
        self.next_group_index += 1;
        self.groups_remaining -= 1;
        return true;
    }

    fn loadNextNonEmptyMask(self: *DfsFrame, view: *const common.CapturedGraphView) bool {
        while (true) {
            while (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup(view)) return false;
            }

            const block_idx = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            const block = page_ops.edgeBlockAtConst(view.core, block_idx, .fwd);
            if (block.mask == 0) continue;
            self.current_mask = block.mask;
            self.cached_fwd_block = block;
            return true;
        }
    }

    fn next(self: *DfsFrame, view: *const common.CapturedGraphView) ?types.NodeId {
        while (true) {
            while (self.current_mask == 0) {
                if (!self.loadNextNonEmptyMask(view)) return null;
            }

            const bit_index: u6 = @intCast(@ctz(self.current_mask));
            self.current_mask &= self.current_mask - 1;
            const neighbor = types.NodeId{ .index = self.cached_fwd_block.?.edges[bit_index].destination };
            if (neighbor.index >= view.nodeCount()) continue;
            if (self.check_removed_candidates and !view.isLiveIndex(neighbor.index)) continue;
            return neighbor;
        }
    }
};

fn initFrame(view: *const common.CapturedGraphView, node: types.NodeId) types.GraphError!?DfsFrame {
    if (node.index >= view.nodeCount()) return null;
    if (!view.isLiveIndex(node.index)) return null;

    const snapshot_side = view.fwd_side[node.index];
    if (snapshot_side.block_count == 0) {
        return .{
            .current_block_index = 0,
            .blocks_remaining = 0,
            .next_group_index = 0,
            .groups_remaining = 0,
            .current_mask = 0,
            .check_removed_candidates = view.needsRepairFwd(node.index),
        };
    }

    if (snapshot_side.group_count == 0) {
        return .{
            .current_block_index = snapshot_side.first_block,
            .blocks_remaining = snapshot_side.block_count,
            .next_group_index = 0,
            .groups_remaining = 0,
            .current_mask = 0,
            .check_removed_candidates = view.needsRepairFwd(node.index),
        };
    }

    return .{
        .current_block_index = 0,
        .blocks_remaining = 0,
        .next_group_index = snapshot_side.first_group,
        .groups_remaining = snapshot_side.group_count,
        .current_mask = 0,
        .check_removed_candidates = view.needsRepairFwd(node.index),
    };
}

/// Returns nodes in depth-first order starting from `start` over a fixed
/// captured graph view.
pub fn dfsCaptured(view: *const common.CapturedGraphView, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    const node_count = view.nodeCount();
    try view.ensureLiveStart(start);

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var stack = try std.ArrayList(DfsFrame).initCapacity(allocator, @min(node_count, 64));
    defer stack.deinit(allocator);
    var order = try std.ArrayList(types.NodeId).initCapacity(allocator, node_count);
    errdefer order.deinit(allocator);

    visited.set(start.index);
    try order.append(allocator, start);
    try stack.append(allocator, (try initFrame(view, start)) orelse return error.InvalidNode);

    while (stack.items.len > 0) {
        const current = &stack.items[stack.items.len - 1];

        var pushed = false;
        while (current.next(view)) |neighbor| {
            if (visited.isSet(neighbor.index)) continue;

            if (try initFrame(view, neighbor)) |next_frame| {
                visited.set(neighbor.index);
                try order.append(allocator, neighbor);
                try stack.append(allocator, next_frame);
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
