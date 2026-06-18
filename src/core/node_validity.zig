const graph_core = @import("graph_core.zig");
const node_access = @import("node_access.zig");
const types = @import("types.zig");

pub inline fn nodeExistsRaw(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    return graph.hasNode(node);
}

pub inline fn nodeExistsRawIndex(graph: *const graph_core.GraphCore, node_idx: u32) bool {
    return node_idx < graph.publishedNodeCount();
}

pub fn isNodeRemoved(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    if (!nodeExistsRaw(graph, node)) return false;
    return node_access.loadPublicationStateAtConst(graph, node).removed;
}

pub fn isNodeRemovedIndex(graph: *const graph_core.GraphCore, node_idx: u32) bool {
    if (!nodeExistsRawIndex(graph, node_idx)) return false;
    return node_access.loadPublicationStateAtConst(graph, .{ .index = node_idx }).removed;
}

pub fn isNodeLive(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    return nodeExistsRaw(graph, node) and !isNodeRemoved(graph, node);
}

pub fn isNodeLiveIndex(graph: *const graph_core.GraphCore, node_idx: u32) bool {
    return nodeExistsRawIndex(graph, node_idx) and !isNodeRemovedIndex(graph, node_idx);
}

pub inline fn snapshotIsLive(adjacency: types.NodeAdj) bool {
    return !adjacency.flags.removed;
}

pub fn ensureLiveNode(graph: *const graph_core.GraphCore, node: types.NodeId) !void {
    if (!isNodeLive(graph, node)) return error.InvalidNode;
}

pub fn ensureLiveSnapshot(adjacency: types.NodeAdj) !void {
    if (!snapshotIsLive(adjacency)) return error.InvalidNode;
}
