const std = @import("std");
const internal = @import("../graph.zig");
const public_iterator = @import("public_iterator.zig");
const bfs_internal = @import("../algorithms/bfs.zig");
const dfs_internal = @import("../algorithms/dfs.zig");
const cycle_internal = @import("../algorithms/cycle.zig");

pub const Graph = opaque {
    pub fn init(allocator: std.mem.Allocator) !*Graph {
        const g = try allocator.create(internal.Graph);
        errdefer allocator.destroy(g);
        g.* = try internal.Graph.init(allocator);
        return @ptrCast(g);
    }

    pub fn deinit(self: *Graph) void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        const alloc = g.graph.allocator;
        g.deinit();
        alloc.destroy(g);
    }

    pub fn deinitChecked(self: *Graph) internal.DeinitError!void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.deinitChecked();
    }

    pub fn addNode(self: *Graph) !internal.NodeId {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.addNode();
    }

    pub fn nodeCount(self: *const Graph) usize {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.nodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.edgeCount();
    }

    pub fn hasNode(self: *const Graph, id: internal.NodeId) bool {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.hasNode(id);
    }

    pub fn validate(self: *const Graph) internal.GraphError!void {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.validate();
    }

    pub fn debugValidate(self: *const Graph, allocator: std.mem.Allocator) internal.GraphError![]internal.Violation {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.debugValidate(allocator);
    }

    pub fn neighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!*public_iterator.NeighborIterator {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        const internal_iter = try g.neighbors(node);
        return public_iterator.newNeighborIterator(g.graph.allocator, internal_iter);
    }

    pub fn inNeighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!*public_iterator.NeighborIterator {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        const internal_iter = try g.inNeighbors(node);
        return public_iterator.newNeighborIterator(g.graph.allocator, internal_iter);
    }

    /// Convenience: materializes all outgoing neighbors into a slice.
    /// The caller owns the returned slice.
    pub fn neighborsMaterialized(self: *const Graph, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        var internal_iter = try g.neighbors(node);
        return internal_iter.materialize(allocator);
    }

    /// Convenience: materializes all incoming neighbors into a slice.
    /// The caller owns the returned slice.
    pub fn inNeighborsMaterialized(self: *const Graph, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        var internal_iter = try g.inNeighbors(node);
        return internal_iter.materialize(allocator);
    }

    pub fn outDegree(self: *const Graph, node: internal.NodeId) internal.GraphError!usize {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.outDegree(node);
    }

    pub fn inDegree(self: *const Graph, node: internal.NodeId) internal.GraphError!usize {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.inDegree(node);
    }

    pub fn repairNode(self: *Graph, node: internal.NodeId) internal.GraphError!void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.repairNode(node);
    }

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) internal.GraphError!usize {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.repairBudgeted(max_nodes);
    }

    pub fn addEdge(self: *Graph, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.addEdge(source, destination, relation, @bitCast(flags));
    }

    pub fn removeEdge(self: *Graph, source: internal.NodeId, destination: internal.NodeId) internal.GraphError!bool {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.removeEdge(source, destination);
    }

    pub fn removeNode(self: *Graph, node: internal.NodeId) internal.GraphError!void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        return g.removeNode(node);
    }

    // ── Algorithms (concurrent-safe, evolving valid view) ──────────────

    pub fn bfs(self: *const Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return bfs_internal.bfs(&g.graph, start, allocator);
    }

    pub fn dfs(self: *const Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return dfs_internal.dfs(&g.graph, start, allocator);
    }

    pub fn hasCycle(self: *const Graph, allocator: std.mem.Allocator) internal.GraphError!bool {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return cycle_internal.hasCycle(&g.graph, allocator);
    }
};
