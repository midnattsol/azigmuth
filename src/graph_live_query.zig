const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const neighbor_iter = @import("neighbor_iterator.zig");
const out_edge_iter = @import("out_edge_iterator.zig");

pub const NeighborIterator = neighbor_iter.NeighborIterator;
pub const OutEdgeIterator = out_edge_iter.OutEdgeIterator;

pub fn neighbors(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return neighbor_iter.neighbors(core, node);
}

pub fn inNeighbors(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return neighbor_iter.inNeighbors(core, node);
}

pub fn outDegree(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    return neighbor_iter.outDegree(core, node);
}

pub fn inDegree(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    return neighbor_iter.inDegree(core, node);
}

pub fn outEdges(core: *graph_core.GraphCore, node: types.NodeId) types.GraphError!OutEdgeIterator {
    if (!core.multigraph_enabled) return error.UnsupportedOperation;
    return out_edge_iter.outEdges(core, node);
}
