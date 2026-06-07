//! Public `Graph` handle — heap-allocated opaque type that forms the canonical
//! entry point for core storage, mutation, validation, and maintenance
//! operations. Callers never see the internal layout and must go through the
//! methods defined here.
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
//!     `validate`, `debugValidate`) are lock-free readers and never block
//!     writers.

const std = @import("std");
const internal = @import("../graph.zig");

pub const Graph = opaque {
    fn inner(self: *Graph) *internal.Graph {
        return @ptrCast(@alignCast(self));
    }

    fn innerConst(self: *const Graph) *const internal.Graph {
        return @ptrCast(@alignCast(self));
    }

    /// Allocates and returns a heap-allocated `*Graph`.  The caller owns the
    /// returned pointer and must call `deinit()` or `deinitChecked()` when done.
    pub fn init(allocator: std.mem.Allocator) internal.GraphError!*Graph {
        const g = try allocator.create(internal.Graph);
        errdefer allocator.destroy(g);
        g.* = try internal.Graph.init(allocator);
        return @ptrCast(g);
    }

    /// Allocates and returns a heap-allocated `*Graph` with the given options.
    /// Caller owns the pointer; must call `deinit()` or `deinitChecked()`.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: internal.GraphOptions) internal.GraphError!*Graph {
        const g = try allocator.create(internal.Graph);
        errdefer allocator.destroy(g);
        g.* = try internal.Graph.initWithOptions(allocator, options);
        return @ptrCast(g);
    }

    /// Destroys the graph handle unconditionally.  All page-backed storage,
    /// repair queues, and the handle itself are freed.
    ///
    /// Must not be called while writers, readers, or repairers are active — use
    /// `deinitChecked()` for a safe teardown check instead. If called while the
    /// graph still has active users, this panics in any build mode with a
    /// diagnostic that includes the active call, writer, repairer, and reader
    /// overflow counts.
    pub fn deinit(self: *Graph) void {
        const g = self.inner();
        const alloc = g.graph.allocator;
        g.deinit();
        alloc.destroy(g);
    }

    /// Safe teardown: returns `error.GraphBusy` if any reader, writer, or
    /// repairer is still active.  On success the handle is consumed just like
    /// `deinit()`.  On `GraphBusy` the handle remains valid — the caller may
    /// drain active operations and retry.
    ///
    /// The success path delegates to `deinit()`, so it inherits the same panic
    /// contract if an impossible post-close active-user state were ever to be
    /// observed.
    pub fn deinitChecked(self: *Graph) internal.DeinitError!void {
        const g = self.inner();
        const alloc = g.graph.allocator;
        g.deinitChecked() catch |err| return err;
        alloc.destroy(g);
    }

    pub fn addNode(self: *Graph) internal.GraphError!internal.NodeId {
        return self.inner().addNode();
    }

    pub fn nodeCount(self: *const Graph) usize {
        return self.innerConst().nodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        return self.innerConst().edgeCount();
    }

    pub fn hasNode(self: *const Graph, id: internal.NodeId) bool {
        return self.innerConst().hasNode(id);
    }

    pub fn validate(self: *const Graph) internal.GraphError!void {
        return self.innerConst().validate();
    }

    pub fn debugValidate(self: *const Graph, allocator: std.mem.Allocator) internal.GraphError![]internal.Violation {
        return self.innerConst().debugValidate(allocator);
    }

    pub fn neighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!internal.NeighborIterator {
        return self.innerConst().neighbors(node);
    }

    pub fn inNeighbors(self: *const Graph, node: internal.NodeId) internal.GraphError!internal.NeighborIterator {
        return self.innerConst().inNeighbors(node);
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
        return self.innerConst().outDegree(node);
    }

    pub fn inDegree(self: *const Graph, node: internal.NodeId) internal.GraphError!usize {
        return self.innerConst().inDegree(node);
    }

    /// Returns edge-aware outgoing iterator. Multigraph mode only.
    pub fn outEdges(self: *const Graph, node: internal.NodeId) internal.GraphError!internal.OutEdgeIterator {
        return self.innerConst().outEdges(node);
    }

    pub fn repairNode(self: *Graph, node: internal.NodeId) internal.GraphError!void {
        return self.inner().repairNode(node);
    }

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) internal.GraphError!usize {
        return self.inner().repairBudgeted(max_nodes);
    }

    pub fn reclaimRetired(self: *Graph) void {
        return self.inner().reclaimRetired();
    }

    pub fn addEdge(self: *Graph, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!void {
        return self.inner().addEdge(source, destination, relation, @bitCast(flags));
    }

    /// Returns the assigned EdgeId in multigraph mode.
    pub fn addEdgeWithId(self: *Graph, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!internal.EdgeId {
        return self.inner().addEdgeWithId(source, destination, relation, @bitCast(flags));
    }

    /// Removes one edge in simple mode, or all duplicates for the pair in multigraph mode.
    pub fn removeEdge(self: *Graph, source: internal.NodeId, destination: internal.NodeId) internal.GraphError!bool {
        return self.inner().removeEdge(source, destination);
    }

    /// Removes exactly the identified edge in multigraph mode.
    pub fn removeEdgeWithId(self: *Graph, source: internal.NodeId, destination: internal.NodeId, edge_id: internal.EdgeId) internal.GraphError!bool {
        return self.inner().removeEdgeWithId(source, destination, edge_id);
    }

    pub fn removeNode(self: *Graph, node: internal.NodeId) internal.GraphError!internal.NodeRemovalSummary {
        return self.inner().removeNode(node);
    }
};
