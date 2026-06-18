const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_adjacency_buffers = @import("../storage/node/adjacency_buffers.zig");
const node_validity = @import("../core/node_validity.zig");
const side_ops = @import("../adjacency/side_ops.zig");
const live_read_common = @import("live_read_common.zig");
const rcu = @import("../concurrency/rcu.zig");
const neighbor_iter = @import("neighbor_iterator.zig");
const out_edge_iter = @import("out_edge_iterator.zig");

pub const NeighborIterator = neighbor_iter.NeighborIterator;
pub const OutEdgeIterator = out_edge_iter.OutEdgeIterator;

/// Returns an iterator over the live forward neighbors of one node.
pub fn neighbors(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return neighbor_iter.neighbors(core, node);
}

/// Returns an iterator over the live reverse neighbors of one node.
pub fn inNeighbors(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return neighbor_iter.inNeighbors(core, node);
}

/// Returns the published forward degree of one live node.
pub fn outDegree(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    return neighbor_iter.outDegree(core, node);
}

/// Returns the published reverse degree of one live node.
pub fn inDegree(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    return neighbor_iter.inDegree(core, node);
}

/// Returns an iterator over outgoing edges with ids, relation, and flags.
/// Available in multigraph mode and in edge_properties mode.
pub fn outEdges(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!core.multigraph_enabled and !core.edge_properties_enabled) return error.UnsupportedOperation;
    return out_edge_iter.outEdges(core, node);
}

/// Point lookup of the stable property row for the edge (source → destination).
/// Returns null when no live edge matches. In multigraph mode the row of an
/// arbitrary matching parallel edge is returned; use outEdges + EdgeId to
/// disambiguate. Requires edge_properties mode.
pub fn edgePropertyRow(core: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId) types.GraphError!?u32 {
    if (!core.edge_properties_enabled) return error.UnsupportedOperation;
    if (!node_validity.isNodeLive(core, destination)) return error.InvalidNode;

    const capture = try live_read_common.captureNodeSnapshot(core, source);
    defer rcu.readerExit(core, capture.reader_token);

    const side = live_read_common.sideAdj(.fwd, capture.node_adj_snapshot);
    const found = side_ops.findSlotInAdj(
        core,
        side.first_block,
        side.block_count,
        side.segment_count,
        side.first_segment,
        destination.index,
        .fwd,
        capture.sorted_fwd,
    ) orelse return null;

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side)) {
        return page_ops.tinySlotAtConst(core, side.first_block, .fwd).entries[found.slot].prop_row;
    }
    return page_ops.edgeBlockFwdPropsAtConst(core, found.block_idx).rows[found.slot];
}
