//! OutEdgeIterator — forward-only edge iterator that exposes EdgeRef (id,
//! destination, relation, flags). Returned by value; creation does not
//! allocate. Shares the same RCU snapshot + group traversal machinery as
//! NeighborIterator and is likewise a logically single-owner value.

const std = @import("std");
const constants = @import("../core/constants.zig");
const side_ops = @import("../adjacency/side_ops.zig");
const graph_core = @import("../core/graph_core.zig");
const side_traversal = @import("side_traversal.zig");
const live_read_common = @import("live_read_common.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_published = @import("../storage/node/published.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_tiny = @import("../storage/node/tiny.zig");
const rcu = @import("../concurrency/rcu.zig");
const node_validity = @import("../core/node_validity.zig");

pub const OutEdgeIterator = struct {
    core: *const graph_core.GraphCore,
    node_adj_snapshot: types.NodeAdj,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_slot: u7 = 0,
    current_live: u7 = 0,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_index: u16 = 0,
    /// Cached so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_fwd_ids: ?*const types.EdgeBlockFwdIds = null,
    cached_fwd_props: ?*const types.EdgeBlockFwdProps = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,
    cached_span_page_index: u32 = constants.END_OF_CHAIN,
    cached_span_blocks_raw: usize = 0,
    cached_span_live_raw: usize = 0,
    cached_node_page_index: u32 = constants.END_OF_CHAIN,
    cached_node_page: ?[]const node_meta_mod.NodeMeta = null,
    check_removed_destinations: bool,

    reader_active: bool,
    reader_token: rcu.ReaderToken,
    reader_token_retained: bool = false,

    /// Safeguard against corrupt cyclic group chains.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *OutEdgeIterator) bool {
        return side_traversal.advanceToNextGroup(self, self.core);
    }

    fn destinationRemoved(self: *OutEdgeIterator, destination_index: u32) bool {
        if (!self.check_removed_destinations) return false;
        return live_read_common.candidateRemoved(self, self.core, destination_index);
    }

    fn nextTinyOutEdge(self: *OutEdgeIterator) ?types.EdgeRef {
        while (self.tiny_index < self.tiny_count) : (self.tiny_index += 1) {
            const entry = self.cached_tiny_fwd.?.entries[self.tiny_index];
            if (self.destinationRemoved(entry.destination)) continue;
            self.tiny_index += 1;
            return types.EdgeRef{
                .id = .{ .local = entry.edge_id },
                .destination = entry.destination,
                .relation = entry.relation,
                .flags = entry.flags,
                .property_row = entry.prop_row,
            };
        }
        return null;
    }

    fn nextBlockOutEdge(self: *OutEdgeIterator) ?types.EdgeRef {
        while (true) {
            while (self.current_slot >= self.current_live) {
                // Token liveness is validated once per block span (see
                // NeighborIterator.nextBlockNeighbor).
                if (!rcu.readerTokenActive(self.core, self.reader_token)) {
                    self.reader_active = false;
                    return null;
                }
                if (!side_traversal.loadNextOutEdgeSpan(self, self.core)) return null;
            }

            const slot = self.current_slot;
            self.current_slot += 1;

            const fwd_block = self.cached_fwd_block.?;
            const destination_idx = fwd_block.destinations[slot];

            if (self.destinationRemoved(destination_idx)) continue;

            return types.EdgeRef{
                .id = .{ .local = if (self.cached_fwd_ids) |fwd_ids| fwd_ids.ids[slot] else 0 },
                .destination = destination_idx,
                .relation = fwd_block.relations[slot],
                .flags = @bitCast(fwd_block.flags[slot]),
                .property_row = if (self.cached_fwd_props) |fwd_props| fwd_props.rows[slot] else 0,
            };
        }
    }

    /// Returns the next outgoing edge with its identity, or null when exhausted.
    pub fn next(self: *OutEdgeIterator) ?types.EdgeRef {
        if (!self.reader_active) return null;
        if (self.tiny_mode) {
            if (!rcu.readerTokenActive(self.core, self.reader_token)) {
                self.reader_active = false;
                return null;
            }
            return self.nextTinyOutEdge();
        }
        return self.nextBlockOutEdge();
    }

    pub fn deinit(self: *OutEdgeIterator) void {
        live_read_common.deinitReader(self, self.core);
    }
};

/// Creates an OutEdgeIterator for the given node. Returns by value.
/// Available in multigraph mode and in edge_properties mode.
pub fn outEdges(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!graph.multigraph_enabled and !graph.edge_properties_enabled) return error.UnsupportedOperation;
    const capture = try live_read_common.captureNodeSnapshot(graph, node);
    errdefer live_read_common.releaseCapturedReader(graph, capture);
    const side_snapshot = live_read_common.sideAdj(.fwd, capture.node_adj_snapshot);
    try live_read_common.validateForwardSideQuick(graph, side_snapshot);

    const cursor_init = side_traversal.buildCursorInit(side_snapshot);

    var iterator = OutEdgeIterator{
        .core = graph,
        .node_adj_snapshot = capture.node_adj_snapshot,
        .contiguous_mode = cursor_init.traversal.contiguous_mode,
        .current_block_index = cursor_init.traversal.current_block_index,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_group_index = cursor_init.traversal.current_group_index,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .check_removed_destinations = capture.node_adj_snapshot.flags.needs_repair_fwd,
        .reader_active = true,
        .reader_token = capture.reader_token,
        .groups_visited = 0,
        .group_count_bound = cursor_init.group_count_bound,
    };

    if (iterator.tiny_mode) {
        iterator.cached_tiny_fwd = page_ops.tinyFwdAtConst(graph, iterator.tiny_slot);
    }
    side_traversal.primeGroupedTraversal(&iterator, graph);

    return iterator;
}
