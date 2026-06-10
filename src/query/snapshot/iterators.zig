const std = @import("std");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const side_traversal = @import("../side_traversal.zig");
const snapshot_capture = @import("capture.zig");
const snapshot_view = @import("view.zig");
const node_tiny = @import("../../storage/node/tiny.zig");
const page_ops = @import("../../storage/page_ops.zig");

fn ensureLiveSnapshotNode(view: *const snapshot_view.CapturedGraphView, node: types.NodeId) ?u32 {
    if (node.index >= view.node_state.len) return null;
    if (!view.isLiveIndex(node.index)) return null;
    return node.index;
}

fn initNeighborCursor(
    view: *const snapshot_view.CapturedGraphView,
    direction: adjacency.AdjSide,
    side_snapshot: types.SideAdj,
    check_removed_candidates: bool,
    degree_hint: u32,
) SnapshotNeighborIterator {
    const cursor_init = side_traversal.buildCursorInit(side_snapshot);
    var cursor = SnapshotNeighborIterator{
        .view = view,
        .direction = direction,
        .contiguous_mode = cursor_init.traversal.contiguous_mode,
        .current_block_index = cursor_init.traversal.current_block_index,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_group_index = cursor_init.traversal.current_group_index,
        .current_mask = 0,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .check_removed_candidates = check_removed_candidates,
        .group_count_bound = cursor_init.group_count_bound,
        .degree_hint = degree_hint,
    };
    if (cursor.tiny_mode) {
        switch (direction) {
            .fwd => cursor.cached_tiny_fwd = page_ops.tinyFwdAtConst(view.core, cursor.tiny_slot),
            .rev => cursor.cached_tiny_rev = page_ops.tinyRevAtConst(view.core, cursor.tiny_slot),
        }
    }
    side_traversal.primeGroupedTraversal(&cursor, view.core);
    return cursor;
}

fn initOutEdgeCursor(
    view: *const snapshot_view.CapturedGraphView,
    side_snapshot: types.SideAdj,
    check_removed_destinations: bool,
) SnapshotOutEdgeIterator {
    const cursor_init = side_traversal.buildCursorInit(side_snapshot);
    var iterator = SnapshotOutEdgeIterator{
        .view = view,
        .contiguous_mode = cursor_init.traversal.contiguous_mode,
        .current_block_index = cursor_init.traversal.current_block_index,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_group_index = cursor_init.traversal.current_group_index,
        .current_mask = 0,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .check_removed_destinations = check_removed_destinations,
        .group_count_bound = cursor_init.group_count_bound,
    };
    if (iterator.tiny_mode) {
        iterator.cached_tiny_fwd = page_ops.tinyFwdAtConst(view.core, iterator.tiny_slot);
    }
    side_traversal.primeGroupedTraversal(&iterator, view.core);
    return iterator;
}

pub const SnapshotNeighborIterator = struct {
    view: *const snapshot_view.CapturedGraphView,
    direction: adjacency.AdjSide,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_index: u16 = 0,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,
    cached_tiny_rev: ?*const node_tiny.TinyRevSlot = null,

    check_removed_candidates: bool,
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,
    degree_hint: u32 = 0,

    fn advanceToNextGroup(self: *SnapshotNeighborIterator) bool {
        return side_traversal.advanceToNextGroup(self, self.view.core);
    }

    fn loadNextNonEmptyMask(self: *SnapshotNeighborIterator) bool {
        return side_traversal.loadNextNeighborMask(self, self.view.core);
    }

    fn candidateExcluded(self: *const SnapshotNeighborIterator, candidate_idx: u32) bool {
        if (candidate_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_candidates) return false;
        return !self.view.isLiveIndex(candidate_idx);
    }

    fn nextTinyNeighbor(self: *SnapshotNeighborIterator) ?types.NodeId {
        while (self.tiny_index < self.tiny_count) : (self.tiny_index += 1) {
            const candidate_idx = switch (self.direction) {
                .fwd => self.cached_tiny_fwd.?.entries[self.tiny_index].destination,
                .rev => self.cached_tiny_rev.?.sources[self.tiny_index],
            };
            if (self.candidateExcluded(candidate_idx)) continue;
            self.tiny_index += 1;
            return types.NodeId{ .index = candidate_idx };
        }
        return null;
    }

    fn nextBlockNeighbor(self: *SnapshotNeighborIterator) ?types.NodeId {
        while (true) {
            while (self.current_mask == 0) {
                if (!self.loadNextNonEmptyMask()) return null;
            }

            const bit_index: u6 = @intCast(@ctz(self.current_mask));
            self.current_mask &= self.current_mask - 1;
            const candidate = switch (self.direction) {
                .fwd => types.NodeId{ .index = self.cached_fwd_block.?.edges[bit_index].destination },
                .rev => types.NodeId{ .index = self.cached_rev_block.?.sources[bit_index] },
            };
            if (self.candidateExcluded(candidate.index)) continue;
            return candidate;
        }
    }

    pub fn next(self: *SnapshotNeighborIterator) ?types.NodeId {
        if (self.tiny_mode) return self.nextTinyNeighbor();
        return self.nextBlockNeighbor();
    }

    pub fn materialize(self: *SnapshotNeighborIterator, allocator: std.mem.Allocator) ![]types.NodeId {
        var out = try std.ArrayList(types.NodeId).initCapacity(allocator, self.degree_hint);
        defer out.deinit(allocator);
        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const SnapshotOutEdgeIterator = struct {
    view: *const snapshot_view.CapturedGraphView,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_index: u16 = 0,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_fwd_ids: ?*const types.EdgeBlockFwdIds = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,

    check_removed_destinations: bool,
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *SnapshotOutEdgeIterator) bool {
        return side_traversal.advanceToNextGroup(self, self.view.core);
    }

    fn loadNextNonEmptyMask(self: *SnapshotOutEdgeIterator) bool {
        return side_traversal.loadNextOutEdgeMask(self, self.view.core);
    }

    fn destinationExcluded(self: *const SnapshotOutEdgeIterator, destination_idx: u32) bool {
        if (destination_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_destinations) return false;
        return !self.view.isLiveIndex(destination_idx);
    }

    fn nextTinyOutEdge(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
        while (self.tiny_index < self.tiny_count) : (self.tiny_index += 1) {
            const entry = self.cached_tiny_fwd.?.entries[self.tiny_index];
            if (self.destinationExcluded(entry.destination)) continue;
            self.tiny_index += 1;
            return .{ .id = .{ .local = entry.edge_id }, .destination = entry.destination, .relation = entry.relation, .flags = entry.flags };
        }
        return null;
    }

    fn nextBlockOutEdge(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
        while (true) {
            while (self.current_mask == 0) {
                if (!self.loadNextNonEmptyMask()) return null;
            }

            const bit_index: u6 = @intCast(@ctz(self.current_mask));
            self.current_mask &= self.current_mask - 1;

            const fwd_block = self.cached_fwd_block.?;
            const fwd_ids = self.cached_fwd_ids.?;
            const edge = fwd_block.edges[bit_index];
            if (self.destinationExcluded(edge.destination)) continue;

            return .{ .id = .{ .local = fwd_ids.ids[bit_index] }, .destination = edge.destination, .relation = edge.relation, .flags = @bitCast(edge.flags) };
        }
    }

    pub fn next(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
        if (self.tiny_mode) return self.nextTinyOutEdge();
        return self.nextBlockOutEdge();
    }
};

pub fn neighborsCursor(view: *const snapshot_view.CapturedGraphView, node: types.NodeId) !?SnapshotNeighborIterator {
    const node_idx = ensureLiveSnapshotNode(view, node) orelse return null;
    const side_snapshot = snapshot_capture.sideAdjOfSnapshot(view.fwdSide(node_idx));
    return initNeighborCursor(view, .fwd, side_snapshot, view.needsRepairFwd(node_idx), view.degree_fwd[node_idx]);
}

pub fn inNeighborsCursor(view: *const snapshot_view.CapturedGraphView, node: types.NodeId) !?SnapshotNeighborIterator {
    const node_idx = ensureLiveSnapshotNode(view, node) orelse return null;
    const side_snapshot = snapshot_capture.sideAdjOfSnapshot(view.revSide(node_idx));
    return initNeighborCursor(view, .rev, side_snapshot, view.needsRepairRev(node_idx), view.degree_rev[node_idx]);
}

pub fn outEdges(view: *const snapshot_view.CapturedGraphView, node: types.NodeId) !?SnapshotOutEdgeIterator {
    if (!view.core.multigraph_enabled) return error.UnsupportedOperation;
    const node_idx = ensureLiveSnapshotNode(view, node) orelse return null;
    const side_snapshot = snapshot_capture.sideAdjOfSnapshot(view.fwdSide(node_idx));
    return initOutEdgeCursor(view, side_snapshot, view.needsRepairFwd(node_idx));
}
