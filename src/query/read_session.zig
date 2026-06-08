const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency.zig");
const iterator_common = @import("../iterator_common.zig");
const node_validity = @import("../core/node_validity.zig");
const page_ops = @import("../storage/page_ops.zig");
const rcu = @import("../rcu.zig");
const snapshot_view = @import("snapshot_view.zig");

pub const SnapshotSide = snapshot_view.SnapshotSide;
pub const SnapshotNeighborIterator = snapshot_view.SnapshotNeighborIterator;
pub const SnapshotOutEdgeIterator = snapshot_view.SnapshotOutEdgeIterator;
pub const CapturedGraphView = snapshot_view.CapturedGraphView;

pub const NeighborsCursor = struct {
    core: *const graph_core.GraphCore,
    direction: adjacency.AdjSide,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,
    cached_node_page_index: u32 = constants.END_OF_CHAIN,
    cached_node_page: ?[]const types.NodeBuffer = null,

    check_removed_candidates: bool,
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *NeighborsCursor) bool {
        return iterator_common.advanceToNextGroup(self, self.core);
    }

    fn loadNextNonEmptyMask(self: *NeighborsCursor) bool {
        while (true) {
            while (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup()) return false;
            }

            const block_idx = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            switch (self.direction) {
                .fwd => {
                    const block = page_ops.edgeBlockAtConst(self.core, block_idx, .fwd);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_fwd_block = block;
                    self.cached_rev_block = null;
                },
                .rev => {
                    const block = page_ops.edgeBlockAtConst(self.core, block_idx, .rev);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_rev_block = block;
                    self.cached_fwd_block = null;
                },
            }
            return true;
        }
    }

    fn candidateRemoved(self: *NeighborsCursor, candidate_index: u32) bool {
        if (!self.check_removed_candidates) return false;
        return iterator_common.candidateRemoved(self, self.core, candidate_index);
    }

    pub fn next(self: *NeighborsCursor) ?types.NodeId {
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
            if (self.candidateRemoved(candidate.index)) continue;
            return candidate;
        }
    }
};


pub const ReadSession = struct {
    core: *graph_core.GraphCore,
    reader_token: rcu.ReaderToken,
    active: bool = true,

    pub fn init(core: *graph_core.GraphCore, reader_token: rcu.ReaderToken) ReadSession {
        return .{ .core = core, .reader_token = reader_token };
    }

    pub fn deinit(self: *ReadSession) void {
        if (!self.active) return;
        rcu.readerExit(self.core, self.reader_token);
        _ = self.core.call_state.fetchSub(1, .acq_rel);
        self.active = false;
    }

    pub fn nodeCount(self: *const ReadSession) u32 {
        return self.core.publishedNodeCount();
    }

    /// Captures a sealed in-memory graph view before traversal. The returned
    /// view owns copied node snapshots (adjacency + exact degrees); the
    /// originating read session must stay alive while the view is used so
    /// retired blocks remain pinned.
    pub fn takeSnapshot(self: *const ReadSession, allocator: std.mem.Allocator) !CapturedGraphView {
        return snapshot_view.captureGraphView(self.core, allocator);
    }

    pub fn ensureLiveStart(self: *const ReadSession, node: types.NodeId) types.GraphError!void {
        return node_validity.ensureLiveNode(self.core, node);
    }

    pub fn isNodeRemovedIndex(self: *const ReadSession, node_idx: u32) bool {
        return node_validity.isNodeRemovedIndex(self.core, node_idx);
    }

    pub fn isNodeLiveIndex(self: *const ReadSession, node_idx: u32) bool {
        return node_validity.isNodeLiveIndex(self.core, node_idx);
    }

    pub fn neighborsCursor(self: *const ReadSession, node: types.NodeId) types.GraphError!?NeighborsCursor {
        return self.sideCursor(node, .fwd);
    }

    pub fn inNeighborsCursor(self: *const ReadSession, node: types.NodeId) types.GraphError!?NeighborsCursor {
        return self.sideCursor(node, .rev);
    }

    fn sideCursor(self: *const ReadSession, node: types.NodeId, comptime side: adjacency.AdjSide) types.GraphError!?NeighborsCursor {
        if (!node_validity.nodeExistsRaw(self.core, node)) return null;

        const node_buffer = page_ops.nodeAtConst(self.core, node);
        const meta = node_buffer.loadPublishedMeta();
        const node_adj_snapshot = node_buffer.publishedAdjFromMeta(meta);
        if (!node_validity.snapshotIsLive(node_adj_snapshot)) return null;

        const side_snapshot = adjacency.sideAdjOfNode(node_adj_snapshot, side);
        try iterator_common.validateReadSideQuick(self.core, side_snapshot, side);
        const initial = iterator_common.buildTraversalState(side_snapshot);

        var cursor = NeighborsCursor{
            .core = self.core,
            .direction = side,
            .contiguous_mode = initial.contiguous_mode,
            .current_block_index = initial.current_block_index,
            .blocks_remaining = initial.blocks_remaining,
            .current_group_index = initial.current_group_index,
            .current_mask = 0,
            .check_removed_candidates = switch (side) {
                .fwd => node_adj_snapshot.flags.needs_repair_fwd,
                .rev => node_adj_snapshot.flags.needs_repair_rev,
            },
            .group_count_bound = switch (side) {
                .fwd => node_adj_snapshot.group_count_fwd,
                .rev => node_adj_snapshot.group_count_rev,
            },
        };
        iterator_common.primeGroupedTraversal(&cursor, self.core);
        return cursor;
    }
};
