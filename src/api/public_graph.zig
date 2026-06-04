//! Public `Graph` handle — heap-allocated opaque type that forms the single
//! canonical entry point for all graph operations.  Callers never see the
//! internal layout and must go through the methods defined here.
//!
//! Lifetime:
//!   - `init(allocator)` allocates and returns a `*Graph`.  The caller owns the
//!     pointer and must call `deinit()` or `deinitChecked()`.
//!   - `deinit()` consumes the handle unconditionally.
//!   - `deinitChecked()` consumes the handle only on success; on
//!     `error.GraphBusy` the handle remains valid and can be retried later
//!     (all active iterators or pending calls must release first).
//!   - While `deinitChecked()` has atomically closed the graph to new work,
//!     fallible APIs MAY return `error.GraphBusy`; non-fallible accessors
//!     (`hasNode`, `nodeCount`, `edgeCount`) return safe defaults.
//!   - All query methods (`neighbors`, `inNeighbors`, `outDegree`, `inDegree`,
//!     `bfs`, `dfs`, `hasCycle`, `validate`, `debugValidate`) are lock-free
//!     readers and never block writers.

const std = @import("std");
const internal = @import("../graph.zig");
const public_iterator = @import("public_iterator.zig");

pub const Graph = opaque {
    /// Allocates and returns a heap-allocated `*Graph`.  The caller owns the
    /// returned pointer and must call `deinit()` or `deinitChecked()` when done.
    pub fn init(allocator: std.mem.Allocator) internal.GraphError!*Graph {
        const g = try allocator.create(internal.Graph);
        errdefer allocator.destroy(g);
        g.* = try internal.Graph.init(allocator);
        return @ptrCast(g);
    }

    /// Destroys the graph handle unconditionally.  All page-backed storage,
    /// repair queues, and the handle itself are freed.  Must not be called while
    /// writers, readers, or repairers are active — use `deinitChecked()` for a
    /// safe teardown check.
    pub fn deinit(self: *Graph) void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        const alloc = g.graph.allocator;
        g.deinit();
        alloc.destroy(g);
    }

    /// Safe teardown: returns `error.GraphBusy` if any reader, writer, or
    /// repairer is still active.  On success the handle is consumed just like
    /// `deinit()`.  On `GraphBusy` the handle remains valid — the caller may
    /// drain active operations and retry.
    pub fn deinitChecked(self: *Graph) internal.DeinitError!void {
        const g: *internal.Graph = @ptrCast(@alignCast(self));
        const alloc = g.graph.allocator;
        g.deinitChecked() catch |err| return err;
        alloc.destroy(g);
    }

    pub fn addNode(self: *Graph) internal.GraphError!internal.NodeId {
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

    pub fn neighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!public_iterator.NeighborIterator {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return public_iterator.NeighborIterator.initFromInternal(try g.neighbors(node));
    }

    pub fn inNeighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!public_iterator.NeighborIterator {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return public_iterator.NeighborIterator.initFromInternal(try g.inNeighbors(node));
    }

    /// Convenience: materializes all outgoing neighbors into a slice.
    /// The caller owns the returned slice.
    pub fn neighborsMaterialized(self: *const Graph, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        var it = try self.neighbors(node);
        defer it.deinit();
        return it.materialize(allocator);
    }

    /// Convenience: materializes all incoming neighbors into a slice.
    /// The caller owns the returned slice.
    pub fn inNeighborsMaterialized(self: *const Graph, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        var it = try self.inNeighbors(node);
        defer it.deinit();
        return it.materialize(allocator);
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
        return g.bfs(start, allocator);
    }

    pub fn dfs(self: *const Graph, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.dfs(start, allocator);
    }

    pub fn hasCycle(self: *const Graph, allocator: std.mem.Allocator) internal.GraphError!bool {
        const g: *const internal.Graph = @ptrCast(@alignCast(self));
        return g.hasCycle(allocator);
    }
};
