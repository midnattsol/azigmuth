const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
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
pub fn outEdges(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!core.multigraph_enabled) return error.UnsupportedOperation;
    return out_edge_iter.outEdges(core, node);
}
