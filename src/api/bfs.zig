const std = @import("std");
const internal = @import("../graph.zig");
const public_graph = @import("public_graph.zig");
const bfs_internal = @import("../algorithms/bfs.zig");

pub fn bfs(graph: *const public_graph.Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
    const g: *const internal.Graph = @ptrCast(@alignCast(graph));
    return bfs_internal.bfs(&g.graph, start, allocator);
}
