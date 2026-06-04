const graph_core = @import("graph_core.zig");
const page_ops = @import("../storage/page_ops.zig");
const types = @import("types.zig");

pub inline fn nodeExistsRaw(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    return graph.hasNode(node);
}

pub inline fn nodeExistsRawIndex(graph: *const graph_core.GraphCore, node_index: u32) bool {
    return node_index < graph.publishedNodeCount();
}

pub fn isNodeRemoved(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    if (!nodeExistsRaw(graph, node)) return false;
    return page_ops.nodeAtConst(graph, node).loadPublishedMeta().removed;
}

pub fn isNodeRemovedIndex(graph: *const graph_core.GraphCore, node_index: u32) bool {
    if (!nodeExistsRawIndex(graph, node_index)) return false;
    return page_ops.nodeAtConst(graph, .{ .index = node_index }).loadPublishedMeta().removed;
}

pub fn isNodeLive(graph: *const graph_core.GraphCore, node: types.NodeId) bool {
    return nodeExistsRaw(graph, node) and !isNodeRemoved(graph, node);
}

pub fn isNodeLiveIndex(graph: *const graph_core.GraphCore, node_index: u32) bool {
    return nodeExistsRawIndex(graph, node_index) and !isNodeRemovedIndex(graph, node_index);
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
