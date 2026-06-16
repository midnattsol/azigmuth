//! Public `ReadSnapshot` handle — heap-allocated opaque snapshot captured from a
//! live graph. It owns the copied logical node view and keeps the originating
//! read guard alive until `deinit()`.
//!
//! Consistency contract: the captured view is **per-node coherent**, not a
//! global point-in-time image. Each node's adjacency descriptor, flags, and
//! degrees come from one atomic publication of that node, but two different
//! nodes may be captured around a concurrent multi-node mutation (e.g. a
//! predecessor already reflecting a `removeNode` whose target was captured
//! alive). Serialize writers against `snapshot()` externally when a globally
//! consistent image is required.
//!
//! Lifetime/memory contract: while a `ReadSnapshot` is alive it pins a reader
//! epoch, which prevents reclamation of every block retired after capture.
//! Long-lived analytical views over a mutating graph should call
//! `materializeCsr()` and release the snapshot: the returned `CsrView` is a
//! detached flat-array copy that pins nothing.

const std = @import("std");
const internal = @import("../graph.zig");

pub const ReadSnapshot = opaque {
    fn inner(self: *ReadSnapshot) *internal.ReadSnapshot {
        return @ptrCast(@alignCast(self));
    }

    fn innerConst(self: *const ReadSnapshot) *const internal.ReadSnapshot {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *ReadSnapshot) void {
        const snapshot = self.inner();
        const allocator = snapshot.allocator;
        snapshot.deinit();
        allocator.destroy(snapshot);
    }

    pub fn nodeCount(self: *const ReadSnapshot) usize {
        return self.innerConst().nodeCount();
    }

    pub fn neighbors(self: *const ReadSnapshot, node: internal.NodeId) internal.GraphError!internal.SnapshotNeighborIterator {
        return self.innerConst().neighbors(node);
    }

    pub fn inNeighbors(self: *const ReadSnapshot, node: internal.NodeId) internal.GraphError!internal.SnapshotNeighborIterator {
        return self.innerConst().inNeighbors(node);
    }

    pub fn neighborsMaterialized(self: *const ReadSnapshot, node: internal.NodeId, ctx: internal.Context) internal.GraphError![]internal.NodeId {
        return self.innerConst().neighborsMaterialized(node, ctx);
    }

    pub fn inNeighborsMaterialized(self: *const ReadSnapshot, node: internal.NodeId, ctx: internal.Context) internal.GraphError![]internal.NodeId {
        return self.innerConst().inNeighborsMaterialized(node, ctx);
    }

    pub fn outDegree(self: *const ReadSnapshot, node: internal.NodeId) internal.GraphError!usize {
        return self.innerConst().outDegree(node);
    }

    pub fn inDegree(self: *const ReadSnapshot, node: internal.NodeId) internal.GraphError!usize {
        return self.innerConst().inDegree(node);
    }

    pub fn outEdges(self: *const ReadSnapshot, node: internal.NodeId) internal.GraphError!internal.SnapshotOutEdgeIterator {
        return self.innerConst().outEdges(node);
    }

    pub fn validate(self: *const ReadSnapshot) internal.GraphError!void {
        return self.innerConst().validate();
    }

    pub fn debugValidate(self: *const ReadSnapshot, ctx: internal.Context) internal.GraphError![]internal.Violation {
        return self.innerConst().debugValidate(ctx);
    }

    pub fn bfs(self: *const ReadSnapshot, start: internal.NodeId, ctx: internal.Context) internal.GraphError![]internal.NodeId {
        return self.innerConst().bfs(start, ctx);
    }

    pub fn dfs(self: *const ReadSnapshot, start: internal.NodeId, ctx: internal.Context) internal.GraphError![]internal.NodeId {
        return self.innerConst().dfs(start, ctx);
    }

    pub fn hasCycle(self: *const ReadSnapshot, ctx: internal.Context) internal.GraphError!bool {
        return self.innerConst().hasCycle(ctx);
    }

    pub fn wayfind(self: *const ReadSnapshot, plan: internal.Wayfind.Plan, ctx: internal.Context, params: internal.Wayfind.Params) internal.Wayfind.ExecError!internal.Wayfind.Result {
        return self.innerConst().wayfind(plan, ctx, params);
    }

    /// Copies the snapshot's logical forward adjacency into caller-owned flat
    /// CSR arrays (`out_offsets` + `out_targets`). The result is detached from
    /// the graph: it remains valid after this snapshot — and the graph itself —
    /// are deinitialized, and it does not block retired-storage reclamation.
    /// Intended for hand-off to external analytics tooling and for bounded-
    /// memory long-lived read views. Caller frees with `CsrView.deinit`.
    pub fn materializeCsr(self: *const ReadSnapshot, ctx: internal.Context) internal.GraphError!internal.CsrView {
        return self.innerConst().materializeCsr(ctx);
    }
};
