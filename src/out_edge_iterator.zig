//! OutEdgeIterator — forward-only edge iterator that exposes EdgeRef (id,
//! destination, relation, flags). Returned by value; creation does not
//! allocate. Shares the same RCU snapshot + group traversal machinery as
//! NeighborIterator and is likewise a logically single-owner value.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const iterator_common = @import("iterator_common.zig");
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
    cached_node_page_index: u32 = constants.END_OF_CHAIN,
    cached_node_page: ?[]const types.NodeBuffer = null,

    reader_active: bool,
    reader_token: rcu.ReaderToken,

    /// Safeguard against corrupt cyclic group chains.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *OutEdgeIterator) bool {
        return iterator_common.advanceToNextGroup(self, self.core);
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

    fn destinationRemoved(self: *OutEdgeIterator, destination_index: u32) bool {
        return iterator_common.candidateRemoved(self, self.core, destination_index);
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

            if (self.destinationRemoved(destination.index)) continue;

            return types.EdgeRef{
                .id = .{ .local = fwd_ids.ids[bit_index] },
                .destination = edge.destination,
                .relation = edge.relation,
                .flags = @bitCast(edge.flags), // Edge -> EdgeFlags: both packed struct(u16)
            };
        }
    }

    pub fn deinit(self: *OutEdgeIterator) void {
        iterator_common.deinitReader(self, self.core);
    }
};

fn forwardSideAdj(node_adj: types.NodeAdj) types.SideAdj {
    return .{
        .first_block = node_adj.first_block_fwd,
        .block_count = node_adj.block_count_fwd,
        .group_count = node_adj.group_count_fwd,
        .first_group = node_adj.first_group_fwd,
    };
}

/// Creates an OutEdgeIterator for the given node. Returns by value.
pub fn outEdges(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const reader_token = try rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const meta = node_buffer.loadPublishedMeta();
    const node_adj_snapshot = node_buffer.publishedAdjFromMeta(meta);
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);
    const side_snapshot = forwardSideAdj(node_adj_snapshot);
    try iterator_common.validateReadSideQuick(graph, side_snapshot, .fwd);

    const initial = iterator_common.buildTraversalState(side_snapshot);

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

    iterator_common.primeGroupedTraversal(&iterator, graph);

    return iterator;
}
