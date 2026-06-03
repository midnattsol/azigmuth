const std = @import("std");
const internal = @import("../graph.zig");
const public_graph = @import("public_graph.zig");
const dfs_internal = @import("../algorithms/dfs.zig");

pub fn dfs(graph: *const public_graph.Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
    const g: *const internal.Graph = @ptrCast(@alignCast(graph));
    return dfs_internal.dfs(&g.graph, start, allocator);
}
