const std = @import("std");
const graph_mod = @import("graph.zig");

const Allocator = std.mem.Allocator;

pub fn requireNeighborsAndNodeCount(comptime G: type) void {
    if (!@hasDecl(G, "neighbors"))
        @compileError("Graph must expose fn neighbors(self, NodeId) NeighborIterator");
    if (!@hasDecl(G, "nodeCount"))
        @compileError("Graph must expose fn nodeCount(self) usize");
}

pub fn validateNode(graph: anytype, start: graph_mod.NodeId) !void {
    comptime requireNeighborsAndNodeCount(@TypeOf(graph));
    if (start.index >= graph.nodeCount()) return error.InvalidNode;
}

pub fn buildTestGraph(
    allocator: Allocator,
    comptime node_count: u32,
    comptime edges: []const [2]u32,
) !graph_mod.Graph {
    var graph = try graph_mod.Graph.init(allocator);

    var node_ids: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        node_ids[i] = try graph.addNode();
    }

    for (edges) |edge_pair| {
        try graph.addEdge(node_ids[edge_pair[0]], node_ids[edge_pair[1]], 0, 0);
    }

    return graph;
}
