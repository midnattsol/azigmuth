//! OutEdgeIterator — forward-only edge iterator that exposes EdgeRef (id,
//! destination, relation, flags). Returned by value; creation does not
//! allocate. Shares the same RCU snapshot + group traversal machinery as
//! NeighborIterator and is likewise a logically single-owner value.

const std = @import("std");
const adjacency = @import("adjacency.zig");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const rcu = @import("rcu.zig");
const node_validity = @import("core/node_validity.zig");

pub const OutEdgeIterator = struct {
    core: *const graph_core.GraphCore,
    node_adj_snapshot: types.NodeAdj,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    /// Cached so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_fwd_ids: ?*const types.EdgeBlockFwdIds = null,

    reader_active: bool,
    reader_token: rcu.ReaderToken,

    /// Safeguard against corrupt cyclic group chains.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *OutEdgeIterator) bool {
        if (self.contiguous_mode) return false;
        if (self.current_group_index == constants.END_OF_CHAIN) return false;

        const current = page_ops.groupAtConst(self.core, self.current_group_index);
        if (current.next == constants.END_OF_CHAIN) {
            self.current_group_index = constants.END_OF_CHAIN;
            return false;
        }

        self.current_group_index = current.next;
        self.groups_visited += 1;
        if (self.groups_visited >= self.group_count_bound) {
            self.current_group_index = constants.END_OF_CHAIN;
            return false;
        }

        const next_group = page_ops.groupAtConst(self.core, self.current_group_index);
        self.current_block_index = next_group.start;
        self.blocks_remaining = next_group.count;
        return true;
    }

    fn loadNextNonEmptyMask(self: *OutEdgeIterator) bool {
        while (true) {
            if (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup()) return false;
            }

            const block_index = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            const block = page_ops.edgeBlockAtConst(self.core, block_index, .fwd);
            if (block.mask == 0) continue;
            self.current_mask = block.mask;
            self.cached_fwd_block = block;
            self.cached_fwd_ids = page_ops.edgeBlockFwdIdsAtConst(self.core, block_index);
            return true;
        }
    }

    /// Returns the next outgoing edge with its identity, or null when exhausted.
    pub fn next(self: *OutEdgeIterator) ?types.EdgeRef {
        if (!self.reader_active) return null;
        if (!rcu.readerTokenActive(self.reader_token)) {
            self.reader_active = false;
            return null;
        }
        while (true) {
            while (self.current_mask == 0) {
                if (!self.loadNextNonEmptyMask()) return null;
            }

            const bit_index: u6 = @intCast(@ctz(self.current_mask));
            self.current_mask &= self.current_mask - 1;

            const fwd_block = self.cached_fwd_block.?;
            const fwd_ids = self.cached_fwd_ids.?;
            const edge = fwd_block.edges[bit_index];
            const destination = types.NodeId{ .index = edge.destination };

            if (node_validity.isNodeRemovedIndex(self.core, destination.index)) continue;

            return types.EdgeRef{
                .id = .{ .local = fwd_ids.ids[bit_index] },
                .destination = edge.destination,
                .relation = edge.relation,
                .flags = @bitCast(edge.flags), // Edge -> EdgeFlags: both packed struct(u16)
            };
        }
    }

    pub fn deinit(self: *OutEdgeIterator) void {
        if (!self.reader_active) return;
        switch (rcu.beginCloseReaderToken(self.reader_token)) {
            .inactive => {},
            .pending => {},
            .finalize => rcu.finalizeReaderExit(@constCast(self.core), self.reader_token),
        }
        self.reader_active = false;
    }
};

fn buildIteratorState(node_adj: types.NodeAdj) struct {
    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,
} {
    const block_count: u32 = node_adj.block_count_fwd;
    const group_count: u32 = node_adj.group_count_fwd;

    if (block_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = 0,
            .blocks_remaining = 0,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    if (group_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = node_adj.first_block_fwd,
            .blocks_remaining = block_count,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    return .{
        .contiguous_mode = false,
        .current_block_index = 0,
        .blocks_remaining = 0,
        .current_group_index = node_adj.first_group_fwd,
    };
}

/// Creates an OutEdgeIterator for the given node. Returns by value.
pub fn outEdges(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const reader_token = try rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const node_adj_snapshot = node_buffer.publishedAdj();
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);
    try adjacency.validateNodeAdjLayout(graph, node_adj_snapshot, .fwd);

    const initial = buildIteratorState(node_adj_snapshot);

    var iterator = OutEdgeIterator{
        .core = graph,
        .node_adj_snapshot = node_adj_snapshot,
        .contiguous_mode = initial.contiguous_mode,
        .current_block_index = initial.current_block_index,
        .blocks_remaining = initial.blocks_remaining,
        .current_group_index = initial.current_group_index,
        .current_mask = 0,
        .reader_active = true,
        .reader_token = reader_token,
        .groups_visited = 0,
        .group_count_bound = node_adj_snapshot.group_count_fwd,
    };

    if (!iterator.contiguous_mode and iterator.current_group_index != constants.END_OF_CHAIN) {
        const first_group = page_ops.groupAtConst(graph, iterator.current_group_index);
        iterator.current_block_index = first_group.start;
        iterator.blocks_remaining = first_group.count;
    }

    return iterator;
}
