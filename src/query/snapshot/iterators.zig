const std = @import("std");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const side_traversal = @import("../side_traversal.zig");
const snapshot_capture = @import("capture.zig");
const snapshot_view = @import("view.zig");
const node_adjacency_buffers = @import("../../storage/node/adjacency_buffers.zig");
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
        .current_block_idx = cursor_init.traversal.current_block_idx,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_segment_idx = cursor_init.traversal.current_segment_idx,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .check_removed_candidates = check_removed_candidates,
        .segment_count_bound = cursor_init.segment_count_bound,
        .degree_hint = degree_hint,
    };
    if (cursor.tiny_mode) {
        switch (direction) {
            .fwd => cursor.cached_tiny_fwd = page_ops.tinySlotAtConst(view.core, cursor.tiny_slot, .fwd),
            .rev => cursor.cached_tiny_rev = page_ops.tinySlotAtConst(view.core, cursor.tiny_slot, .rev),
        }
    }
    side_traversal.primeSegmentedTraversal(&cursor, view.core);
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
        .current_block_idx = cursor_init.traversal.current_block_idx,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_segment_idx = cursor_init.traversal.current_segment_idx,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .check_removed_destinations = check_removed_destinations,
        .segment_count_bound = cursor_init.segment_count_bound,
    };
    if (iterator.tiny_mode) {
        iterator.cached_tiny_fwd = page_ops.tinySlotAtConst(view.core, iterator.tiny_slot, .fwd);
    }
    side_traversal.primeSegmentedTraversal(&iterator, view.core);
    return iterator;
}

pub const SnapshotNeighborIterator = struct {
    view: *const snapshot_view.CapturedGraphView,
    direction: adjacency.AdjSide,

    contiguous_mode: bool,
    current_block_idx: u32,
    blocks_remaining: u32,
    current_segment_idx: u32,

    current_slot: u7 = 0,
    current_live: u7 = 0,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_idx: u16 = 0,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,
    cached_tiny_rev: ?*const node_tiny.TinyRevSlot = null,
    cached_span_page_idx: u32 = constants.END_OF_CHAIN,
    cached_span_blocks_raw: usize = 0,
    cached_span_alive_raw: usize = 0,

    check_removed_candidates: bool,
    segments_visited: u16 = 0,
    segment_count_bound: u16 = 0,
    degree_hint: u32 = 0,

    fn advanceToNextSegment(self: *SnapshotNeighborIterator) bool {
        return side_traversal.advanceToNextSegment(self, self.view.core);
    }

    fn loadNextNonEmptySpan(self: *SnapshotNeighborIterator) bool {
        return side_traversal.loadNextNeighborSpan(self, self.view.core);
    }

    fn candidateExcluded(self: *const SnapshotNeighborIterator, candidate_idx: u32) bool {
        if (candidate_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_candidates) return false;
        return !self.view.isLiveIndex(candidate_idx);
    }

    fn nextTinyNeighbor(self: *SnapshotNeighborIterator) ?types.NodeId {
        while (self.tiny_idx < self.tiny_count) : (self.tiny_idx += 1) {
            const candidate_idx = switch (self.direction) {
                .fwd => self.cached_tiny_fwd.?.entries[self.tiny_idx].destination,
                .rev => self.cached_tiny_rev.?.sources[self.tiny_idx],
            };
            if (self.candidateExcluded(candidate_idx)) continue;
            self.tiny_idx += 1;
            return types.NodeId{ .index = candidate_idx };
        }
        return null;
    }

    fn nextBlockNeighborImpl(self: *SnapshotNeighborIterator, comptime check_removed: bool) ?types.NodeId {
        while (true) {
            while (self.current_slot >= self.current_live) {
                if (!self.loadNextNonEmptySpan()) return null;
            }

            const slot = self.current_slot;
            self.current_slot += 1;
            const candidate_idx = switch (self.direction) {
                .fwd => self.cached_fwd_block.?.destinations[slot],
                .rev => self.cached_rev_block.?.sources[slot],
            };
            if (candidate_idx >= self.view.node_state.len) continue;
            if (check_removed and !self.view.isLiveIndex(candidate_idx)) continue;
            return types.NodeId{ .index = candidate_idx };
        }
    }

    pub fn next(self: *SnapshotNeighborIterator) ?types.NodeId {
        if (self.tiny_mode) return self.nextTinyNeighbor();
        if (self.check_removed_candidates) return self.nextBlockNeighborImpl(true);
        return self.nextBlockNeighborImpl(false);
    }

    /// Candidate ids of the cached block from `from_slot` up to the alive
    /// count, as one contiguous slice.
    fn cachedBlockCandidates(self: *const SnapshotNeighborIterator, from_slot: u7) []const u32 {
        return switch (self.direction) {
            .fwd => self.cached_fwd_block.?.destinations[from_slot..self.current_live],
            .rev => self.cached_rev_block.?.sources[from_slot..self.current_live],
        };
    }

    fn appendCandidates(out: *std.ArrayList(types.NodeId), candidates: []const u32, len_bound: usize) void {
        for (candidates) |candidate_idx| {
            if (candidate_idx < len_bound) out.appendAssumeCapacity(.{ .index = candidate_idx });
        }
    }

    pub fn materialize(self: *SnapshotNeighborIterator, allocator: std.mem.Allocator) ![]types.NodeId {
        var out = try std.ArrayList(types.NodeId).initCapacity(allocator, self.degree_hint);
        defer out.deinit(allocator);

        // Clean block sides drain block-by-block: a tight counted append loop
        // per cached block instead of the per-element iterator state machine.
        if (!self.tiny_mode and !self.check_removed_candidates) {
            const len_bound = self.view.node_state.len;

            // Drain a partially consumed block first.
            if (self.current_slot < self.current_live) {
                const partial = self.cachedBlockCandidates(self.current_slot);
                try out.ensureUnusedCapacity(allocator, partial.len);
                appendCandidates(&out, partial, len_bound);
                self.current_slot = self.current_live;
            }

            while (self.loadNextNonEmptySpan()) {
                const candidates = self.cachedBlockCandidates(0);
                try out.ensureUnusedCapacity(allocator, candidates.len);
                appendCandidates(&out, candidates, len_bound);
                self.current_slot = self.current_live;
            }
            return out.toOwnedSlice(allocator);
        }

        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const SnapshotOutEdgeIterator = struct {
    view: *const snapshot_view.CapturedGraphView,

    contiguous_mode: bool,
    current_block_idx: u32,
    blocks_remaining: u32,
    current_segment_idx: u32,

    current_slot: u7 = 0,
    current_live: u7 = 0,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_idx: u16 = 0,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_fwd_ids: ?*const types.EdgeBlockFwdIds = null,
    cached_fwd_props: ?*const types.EdgeBlockFwdProps = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,
    cached_span_page_idx: u32 = constants.END_OF_CHAIN,
    cached_span_blocks_raw: usize = 0,
    cached_span_alive_raw: usize = 0,

    check_removed_destinations: bool,
    segments_visited: u16 = 0,
    segment_count_bound: u16 = 0,

    fn advanceToNextSegment(self: *SnapshotOutEdgeIterator) bool {
        return side_traversal.advanceToNextSegment(self, self.view.core);
    }

    fn loadNextNonEmptySpan(self: *SnapshotOutEdgeIterator) bool {
        return side_traversal.loadNextOutEdgeSpan(self, self.view.core);
    }

    fn destinationExcluded(self: *const SnapshotOutEdgeIterator, destination_idx: u32) bool {
        if (destination_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_destinations) return false;
        return !self.view.isLiveIndex(destination_idx);
    }

    fn nextTinyOutEdge(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
        while (self.tiny_idx < self.tiny_count) : (self.tiny_idx += 1) {
            const entry = self.cached_tiny_fwd.?.entries[self.tiny_idx];
            if (self.destinationExcluded(entry.destination)) continue;
            self.tiny_idx += 1;
            return .{ .id = .{ .local = entry.edge_id }, .destination = entry.destination, .relation = entry.relation, .flags = entry.flags, .property_row = entry.prop_row };
        }
        return null;
    }

    fn nextBlockOutEdge(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
        while (true) {
            while (self.current_slot >= self.current_live) {
                if (!self.loadNextNonEmptySpan()) return null;
            }

            const slot = self.current_slot;
            self.current_slot += 1;

            const fwd_block = self.cached_fwd_block.?;
            const destination_idx = fwd_block.destinations[slot];
            if (self.destinationExcluded(destination_idx)) continue;

            return .{
                .id = .{ .local = if (self.cached_fwd_ids) |fwd_ids| fwd_ids.ids[slot] else 0 },
                .destination = destination_idx,
                .relation = fwd_block.relations[slot],
                .flags = @bitCast(fwd_block.flags[slot]),
                .property_row = if (self.cached_fwd_props) |fwd_props| fwd_props.rows[slot] else 0,
            };
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
    if (!view.core.multigraph_enabled and !view.core.edge_properties_enabled) return error.UnsupportedOperation;
    const node_idx = ensureLiveSnapshotNode(view, node) orelse return null;
    const side_snapshot = snapshot_capture.sideAdjOfSnapshot(view.fwdSide(node_idx));
    return initOutEdgeCursor(view, side_snapshot, view.needsRepairFwd(node_idx));
}

/// Lean full-drain forward-neighbor walk over a captured view: no iterator
/// struct, no per-node zero-init — the BFS/Kahn expansion hot path. Applies
/// the same frontier and tombstone filters as SnapshotNeighborIterator.
pub fn forEachNeighborInView(
    view: *const snapshot_view.CapturedGraphView,
    node_idx: u32,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    const side = view.fwdSide(node_idx);
    if (side.block_count == 0) return;
    const len_bound: u32 = @intCast(view.node_state.len);
    const check_removed = view.needsRepairFwd(node_idx);

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side)) {
        const slot = page_ops.tinySlotAtConst(view.core, side.first_block, .fwd);
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side);
        for (0..count) |entry_idx| {
            const candidate = slot.entries[entry_idx].destination;
            if (candidate >= len_bound) continue;
            if (check_removed and !view.isLiveIndex(candidate)) continue;
            try callback(ctx, candidate);
        }
        return;
    }

    var cursor = side_ops.BlockCursor.init(side);
    var cached_page: u32 = constants.END_OF_CHAIN;
    var blocks_raw: usize = 0;
    var live_raw: usize = 0;
    while (cursor.next(view.core)) |block_idx| {
        const page_idx = block_idx / constants.EDGE_BLOCKS_PER_PAGE;
        const slot_in_page = block_idx % constants.EDGE_BLOCKS_PER_PAGE;
        if (page_idx != cached_page) {
            cached_page = page_idx;
            blocks_raw = page_ops.edgeBlockPageRaw(view.core, page_idx, .fwd);
            live_raw = page_ops.blockAlivePageRaw(view.core, page_idx, .fwd);
        }
        const live_page: [*]const u8 = @ptrFromInt(live_raw);
        const alive: usize = @min(live_page[slot_in_page], constants.EDGES_PER_BLOCK);
        if (alive == 0) continue;
        const blocks: [*]const types.EdgeBlockFwd = @ptrFromInt(blocks_raw);
        for (blocks[slot_in_page].destinations[0..alive]) |candidate| {
            if (candidate >= len_bound) continue;
            if (check_removed and !view.isLiveIndex(candidate)) continue;
            try callback(ctx, candidate);
        }
    }
}

/// Compact resumable forward-neighbor cursor for DFS frames: a fraction of
/// SnapshotNeighborIterator's size and construction cost, with the same
/// frontier and tombstone filters. One frame per stack level, advanced one
/// neighbor at a time.
pub const FrameNeighborCursor = struct {
    block_cursor: side_ops.BlockCursor,
    destinations: [*]const u32 = undefined,
    tiny_entries: [*]const node_tiny.TinyFwdEntry = undefined,
    current_slot: u16 = 0,
    current_live: u16 = 0,
    tiny_mode: bool = false,
    check_removed: bool = false,

    pub fn init(view: *const snapshot_view.CapturedGraphView, node_idx: u32) FrameNeighborCursor {
        const side = view.fwdSide(node_idx);
        const check_removed = view.needsRepairFwd(node_idx);

        if (side.block_count != 0 and node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side)) {
            const slot = page_ops.tinySlotAtConst(view.core, side.first_block, .fwd);
            return .{
                .block_cursor = side_ops.BlockCursor.init(.{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 }),
                .tiny_entries = &slot.entries,
                .current_live = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side),
                .tiny_mode = true,
                .check_removed = check_removed,
            };
        }

        return .{
            .block_cursor = side_ops.BlockCursor.init(side),
            .check_removed = check_removed,
        };
    }

    fn loadNextBlock(self: *FrameNeighborCursor, view: *const snapshot_view.CapturedGraphView) bool {
        while (self.block_cursor.next(view.core)) |block_idx| {
            const alive = page_ops.blockAliveCount(view.core, block_idx, .fwd);
            if (alive == 0) continue;
            self.destinations = &page_ops.edgeBlockFwdAtConst(view.core, block_idx).destinations;
            self.current_slot = 0;
            self.current_live = alive;
            return true;
        }
        return false;
    }

    pub fn next(self: *FrameNeighborCursor, view: *const snapshot_view.CapturedGraphView) ?u32 {
        const len_bound: u32 = @intCast(view.node_state.len);
        if (self.tiny_mode) {
            while (self.current_slot < self.current_live) {
                const candidate = self.tiny_entries[self.current_slot].destination;
                self.current_slot += 1;
                if (candidate >= len_bound) continue;
                if (self.check_removed and !view.isLiveIndex(candidate)) continue;
                return candidate;
            }
            return null;
        }

        while (true) {
            while (self.current_slot >= self.current_live) {
                if (!self.loadNextBlock(view)) return null;
            }
            const candidate = self.destinations[self.current_slot];
            self.current_slot += 1;
            if (candidate >= len_bound) continue;
            if (self.check_removed and !view.isLiveIndex(candidate)) continue;
            return candidate;
        }
    }
};
