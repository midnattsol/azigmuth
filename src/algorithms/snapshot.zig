const std = @import("std");
const bfs_mod = @import("bfs.zig");
const cycle_mod = @import("cycle.zig");
const context_mod = @import("context.zig");
const dfs_mod = @import("dfs.zig");
const validate_mod = @import("../maintenance/validate.zig");
const read_session = @import("../query/read_session.zig");
const snapshot_csr = @import("../query/snapshot/csr.zig");
const snapshot_iterators = @import("../query/snapshot/iterators.zig");
const snapshot_view = @import("../query/snapshot/view.zig");
const types = @import("../core/types.zig");

pub const CsrView = snapshot_csr.CsrView;

pub const ReadSnapshot = struct {
    allocator: std.mem.Allocator,
    read: read_session.ReadSession,
    view: snapshot_view.CapturedGraphView,

    pub fn init(read: read_session.ReadSession, ctx: context_mod.Context) !ReadSnapshot {
        var owned_read = read;
        errdefer owned_read.deinit();

        const view = try owned_read.takeSnapshot(ctx.allocator);
        return .{
            .allocator = ctx.allocator,
            .read = owned_read,
            .view = view,
        };
    }

    pub fn deinit(self: *ReadSnapshot) void {
        self.view.deinit(self.allocator);
        self.read.deinit();
    }

    pub fn nodeCount(self: *const ReadSnapshot) usize {
        return self.view.nodeCount();
    }

    pub fn neighbors(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_iterators.SnapshotNeighborIterator {
        return (try snapshot_iterators.neighborsCursor(&self.view, node)) orelse error.InvalidNode;
    }

    pub fn inNeighbors(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_iterators.SnapshotNeighborIterator {
        return (try snapshot_iterators.inNeighborsCursor(&self.view, node)) orelse error.InvalidNode;
    }

    pub fn neighborsMaterialized(self: *const ReadSnapshot, node: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
        var it = try self.neighbors(node);
        return it.materialize(ctx.allocator);
    }

    pub fn inNeighborsMaterialized(self: *const ReadSnapshot, node: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
        var it = try self.inNeighbors(node);
        return it.materialize(ctx.allocator);
    }

    pub fn outDegree(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!usize {
        return self.view.outDegree(node);
    }

    pub fn inDegree(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!usize {
        return self.view.inDegree(node);
    }

    pub fn outEdges(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_iterators.SnapshotOutEdgeIterator {
        return (try snapshot_iterators.outEdges(&self.view, node)) orelse error.InvalidNode;
    }

    pub fn validate(self: *const ReadSnapshot) types.GraphError!void {
        return validate_mod.validateSnapshot(self.read.core, &self.view);
    }

    pub fn debugValidate(self: *const ReadSnapshot, ctx: context_mod.Context) types.GraphError![]types.Violation {
        return validate_mod.debugValidateSnapshot(self.read.core, &self.view, ctx.allocator);
    }

    pub fn bfs(self: *const ReadSnapshot, start: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
        return bfs_mod.bfsCaptured(&self.view, start, ctx);
    }

    pub fn dfs(self: *const ReadSnapshot, start: types.NodeId, ctx: context_mod.Context) types.GraphError![]types.NodeId {
        return dfs_mod.dfsCaptured(&self.view, start, ctx);
    }

    pub fn hasCycle(self: *const ReadSnapshot, ctx: context_mod.Context) types.GraphError!bool {
        return cycle_mod.hasCycleCaptured(&self.view, ctx);
    }

    /// Copies the snapshot's logical forward adjacency into caller-owned flat
    /// CSR arrays. The result is fully detached: it survives `deinit()` of
    /// this snapshot and of the graph, and it does not pin retired storage.
    pub fn materializeCsr(self: *const ReadSnapshot, ctx: context_mod.Context) types.GraphError!snapshot_csr.CsrView {
        return snapshot_csr.materializeForwardCsr(&self.view, ctx.allocator);
    }
};
