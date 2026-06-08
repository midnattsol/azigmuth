const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency.zig");
const iterator_common = @import("../iterator_common.zig");
const page_ops = @import("../storage/page_ops.zig");

const state_live_bit: u32 = 1 << 0;
const state_needs_repair_fwd_bit: u32 = 1 << 1;
const state_needs_repair_rev_bit: u32 = 1 << 2;

pub const SnapshotSide = extern struct {
    first_block: u32,
    first_group: u32,
    block_count: u16,
    group_count: u16,
    _reserved: u32 = 0,
};

fn snapshotSide(side: types.SideAdj) SnapshotSide {
    return .{
        .first_block = side.first_block,
        .first_group = side.first_group,
        .block_count = side.block_count,
        .group_count = side.group_count,
    };
}

fn sideAdjOfSnapshot(snapshot_side: SnapshotSide) types.SideAdj {
    return .{
        .first_block = snapshot_side.first_block,
        .block_count = snapshot_side.block_count,
        .group_count = snapshot_side.group_count,
        .first_group = snapshot_side.first_group,
    };
}

pub const SnapshotNeighborIterator = struct {
    view: *const CapturedGraphView,
    direction: adjacency.AdjSide,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,

    check_removed_candidates: bool,
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *SnapshotNeighborIterator) bool {
        return iterator_common.advanceToNextGroup(self, self.view.core);
    }

    fn loadNextNonEmptyMask(self: *SnapshotNeighborIterator) bool {
        while (true) {
            while (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup()) return false;
            }

            const block_idx = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            switch (self.direction) {
                .fwd => {
                    const block = page_ops.edgeBlockAtConst(self.view.core, block_idx, .fwd);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_fwd_block = block;
                    self.cached_rev_block = null;
                },
                .rev => {
                    const block = page_ops.edgeBlockAtConst(self.view.core, block_idx, .rev);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_rev_block = block;
                    self.cached_fwd_block = null;
                },
            }
            return true;
        }
    }

    fn candidateExcluded(self: *const SnapshotNeighborIterator, candidate_idx: u32) bool {
        if (candidate_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_candidates) return false;
        return !self.view.isLiveIndex(candidate_idx);
    }

    pub fn next(self: *SnapshotNeighborIterator) ?types.NodeId {
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

    pub fn materialize(self: *SnapshotNeighborIterator, allocator: std.mem.Allocator) ![]types.NodeId {
        var out = try std.ArrayList(types.NodeId).initCapacity(allocator, 0);
        defer out.deinit(allocator);
        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const SnapshotOutEdgeIterator = struct {
    view: *const CapturedGraphView,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_fwd_ids: ?*const types.EdgeBlockFwdIds = null,

    check_removed_destinations: bool,
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *SnapshotOutEdgeIterator) bool {
        return iterator_common.advanceToNextGroup(self, self.view.core);
    }

    fn loadNextNonEmptyMask(self: *SnapshotOutEdgeIterator) bool {
        while (true) {
            while (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup()) return false;
            }

            const block_idx = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            const block = page_ops.edgeBlockAtConst(self.view.core, block_idx, .fwd);
            if (block.mask == 0) continue;
            self.current_mask = block.mask;
            self.cached_fwd_block = block;
            self.cached_fwd_ids = page_ops.edgeBlockFwdIdsAtConst(self.view.core, block_idx);
            return true;
        }
    }

    fn destinationExcluded(self: *const SnapshotOutEdgeIterator, destination_idx: u32) bool {
        if (destination_idx >= self.view.node_state.len) return true;
        if (!self.check_removed_destinations) return false;
        return !self.view.isLiveIndex(destination_idx);
    }

    pub fn next(self: *SnapshotOutEdgeIterator) ?types.EdgeRef {
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

            return .{
                .id = .{ .local = fwd_ids.ids[bit_index] },
                .destination = edge.destination,
                .relation = edge.relation,
                .flags = @bitCast(edge.flags),
            };
        }
    }
};

pub const CapturedGraphView = struct {
    core: *const graph_core.GraphCore,
    node_state: []u32,
    fwd_side: []SnapshotSide,
    rev_side: []SnapshotSide,
    degree_fwd: []u32,
    degree_rev: []u32,
    live_node_count: usize,

    pub fn deinit(self: *CapturedGraphView, allocator: std.mem.Allocator) void {
        allocator.free(self.node_state);
        allocator.free(self.fwd_side);
        allocator.free(self.rev_side);
        allocator.free(self.degree_fwd);
        allocator.free(self.degree_rev);
    }

    pub fn nodeCount(self: *const CapturedGraphView) usize {
        return self.node_state.len;
    }

    pub fn liveNodeCount(self: *const CapturedGraphView) usize {
        return self.live_node_count;
    }

    pub fn isLiveIndex(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_live_bit) != 0;
    }

    pub fn adjacency(self: *const CapturedGraphView, node_idx: u32) types.NodeAdj {
        const node_state = self.node_state[node_idx];
        const fwd_side = self.fwd_side[node_idx];
        const rev_side = self.rev_side[node_idx];
        return .{
            .first_block_fwd = fwd_side.first_block,
            .block_count_fwd = fwd_side.block_count,
            .group_count_fwd = fwd_side.group_count,
            .first_group_fwd = fwd_side.first_group,
            .first_block_rev = rev_side.first_block,
            .block_count_rev = rev_side.block_count,
            .group_count_rev = rev_side.group_count,
            .first_group_rev = rev_side.first_group,
            .flags = .{
                .needs_repair_fwd = (node_state & state_needs_repair_fwd_bit) != 0,
                .needs_repair_rev = (node_state & state_needs_repair_rev_bit) != 0,
                .removed = (node_state & state_live_bit) == 0,
            },
        };
    }

    pub fn needsRepairFwd(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_needs_repair_fwd_bit) != 0;
    }

    fn needsRepairRev(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_needs_repair_rev_bit) != 0;
    }

    pub fn ensureLiveStart(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!void {
        if (node.index >= self.node_state.len) return error.InvalidNode;
        if (!self.isLiveIndex(node.index)) return error.InvalidNode;
    }

    pub fn neighborsCursor(self: *const CapturedGraphView, node: types.NodeId) !?SnapshotNeighborIterator {
        if (node.index >= self.node_state.len) return null;
        if (!self.isLiveIndex(node.index)) return null;

        const side_snapshot = sideAdjOfSnapshot(self.fwd_side[node.index]);
        const initial = iterator_common.buildTraversalState(side_snapshot);

        var cursor = SnapshotNeighborIterator{
            .view = self,
            .direction = .fwd,
            .contiguous_mode = initial.contiguous_mode,
            .current_block_index = initial.current_block_index,
            .blocks_remaining = initial.blocks_remaining,
            .current_group_index = initial.current_group_index,
            .current_mask = 0,
            .check_removed_candidates = self.needsRepairFwd(node.index),
            .group_count_bound = side_snapshot.group_count,
        };
        iterator_common.primeGroupedTraversal(&cursor, self.core);
        return cursor;
    }

    pub fn inNeighborsCursor(self: *const CapturedGraphView, node: types.NodeId) !?SnapshotNeighborIterator {
        if (node.index >= self.node_state.len) return null;
        if (!self.isLiveIndex(node.index)) return null;

        const side_snapshot = sideAdjOfSnapshot(self.rev_side[node.index]);
        const initial = iterator_common.buildTraversalState(side_snapshot);

        var cursor = SnapshotNeighborIterator{
            .view = self,
            .direction = .rev,
            .contiguous_mode = initial.contiguous_mode,
            .current_block_index = initial.current_block_index,
            .blocks_remaining = initial.blocks_remaining,
            .current_group_index = initial.current_group_index,
            .current_mask = 0,
            .check_removed_candidates = self.needsRepairRev(node.index),
            .group_count_bound = side_snapshot.group_count,
        };
        iterator_common.primeGroupedTraversal(&cursor, self.core);
        return cursor;
    }

    pub fn outEdges(self: *const CapturedGraphView, node: types.NodeId) !?SnapshotOutEdgeIterator {
        if (!self.core.multigraph_enabled) return error.UnsupportedOperation;
        if (node.index >= self.node_state.len) return null;
        if (!self.isLiveIndex(node.index)) return null;

        const side_snapshot = sideAdjOfSnapshot(self.fwd_side[node.index]);
        const initial = iterator_common.buildTraversalState(side_snapshot);

        var iterator = SnapshotOutEdgeIterator{
            .view = self,
            .contiguous_mode = initial.contiguous_mode,
            .current_block_index = initial.current_block_index,
            .blocks_remaining = initial.blocks_remaining,
            .current_group_index = initial.current_group_index,
            .current_mask = 0,
            .check_removed_destinations = self.needsRepairFwd(node.index),
            .group_count_bound = side_snapshot.group_count,
        };
        iterator_common.primeGroupedTraversal(&iterator, self.core);
        return iterator;
    }

    pub fn outDegree(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!usize {
        try self.ensureLiveStart(node);
        return self.degree_fwd[node.index];
    }

    pub fn inDegree(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!usize {
        try self.ensureLiveStart(node);
        return self.degree_rev[node.index];
    }
};

const CapturedNodeData = struct {
    state: u32,
    fwd_side: SnapshotSide,
    rev_side: SnapshotSide,
    degree_fwd: u32,
    degree_rev: u32,
};

fn captureNode(node_buffer: *const types.NodeBuffer) CapturedNodeData {
    while (true) {
        const before = node_buffer.loadPublishedMeta();
        const fwd_side = node_buffer.publishedFwdFromMeta(before);
        const rev_side = node_buffer.publishedRevFromMeta(before);
        const after = node_buffer.loadPublishedMeta();
        if (@as(u64, @bitCast(before)) != @as(u64, @bitCast(after))) continue;

        var state: u32 = 0;
        if (!before.removed) state |= state_live_bit;
        if (before.needs_repair_fwd) state |= state_needs_repair_fwd_bit;
        if (before.needs_repair_rev) state |= state_needs_repair_rev_bit;

        return .{
            .state = state,
            .fwd_side = snapshotSide(fwd_side),
            .rev_side = snapshotSide(rev_side),
            .degree_fwd = before.degree_fwd,
            .degree_rev = before.degree_rev,
        };
    }
}

pub fn captureGraphView(core: *const graph_core.GraphCore, allocator: std.mem.Allocator) !CapturedGraphView {
    const node_count = core.publishedNodeCount();
    const node_state = try allocator.alloc(u32, node_count);
    errdefer allocator.free(node_state);
    const fwd_side = try allocator.alloc(SnapshotSide, node_count);
    errdefer allocator.free(fwd_side);
    const rev_side = try allocator.alloc(SnapshotSide, node_count);
    errdefer allocator.free(rev_side);
    const degree_fwd = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_fwd);
    const degree_rev = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_rev);

    var live_node_count: usize = 0;

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        const captured = captureNode(page_ops.nodeAtConst(core, .{ .index = node_idx }));
        node_state[node_idx_usize] = captured.state;
        fwd_side[node_idx_usize] = captured.fwd_side;
        rev_side[node_idx_usize] = captured.rev_side;
        degree_fwd[node_idx_usize] = captured.degree_fwd;
        degree_rev[node_idx_usize] = captured.degree_rev;
        if ((captured.state & state_live_bit) != 0) live_node_count += 1;
    }

    return .{
        .core = core,
        .node_state = node_state,
        .fwd_side = fwd_side,
        .rev_side = rev_side,
        .degree_fwd = degree_fwd,
        .degree_rev = degree_rev,
        .live_node_count = live_node_count,
    };
}
