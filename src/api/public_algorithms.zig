//! Public algorithm helpers layered on top of the stable `Graph` API.
//! These are intentionally kept outside the core `Graph` handle so the storage
//! engine surface stays focused on storage, mutation, validation, and explicit
//! maintenance tools. Internally they execute against one read session per
//! algorithm call rather than opening a fresh reader for every expanded node.

const std = @import("std");
const bfs_mod = @import("../algorithms/bfs.zig");
const cycle_mod = @import("../algorithms/cycle.zig");
const dfs_mod = @import("../algorithms/dfs.zig");
const public_graph = @import("public_graph.zig");
const internal = @import("../graph.zig");

fn innerConst(graph: *const public_graph.Graph) *const internal.Graph {
    return @ptrCast(@alignCast(graph));
}

pub fn bfs(graph: *const public_graph.Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
    var read = try innerConst(graph).beginReadSession();
    defer read.deinit();
    return bfs_mod.bfs(&read, start, allocator);
}

pub fn dfs(graph: *const public_graph.Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
    var read = try innerConst(graph).beginReadSession();
    defer read.deinit();
    return dfs_mod.dfs(&read, start, allocator);
}

pub fn hasCycle(graph: *const public_graph.Graph, allocator: std.mem.Allocator) internal.GraphError!bool {
    var read = try innerConst(graph).beginReadSession();
    defer read.deinit();
    return cycle_mod.hasCycle(&read, allocator);
}
