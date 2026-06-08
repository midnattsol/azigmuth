const std = @import("std");
const bfs_mod = @import("bfs.zig");
const cycle_mod = @import("cycle.zig");
const dfs_mod = @import("dfs.zig");
const validate_mod = @import("../maintenance/validate.zig");
const read_session = @import("../query/read_session.zig");
const snapshot_view = @import("../query/snapshot_view.zig");
const types = @import("../core/types.zig");

pub const ReadSnapshot = struct {
    allocator: std.mem.Allocator,
    read: read_session.ReadSession,
    view: snapshot_view.CapturedGraphView,

    pub fn init(read: read_session.ReadSession, allocator: std.mem.Allocator) !ReadSnapshot {
        var owned_read = read;
        errdefer owned_read.deinit();

        const view = try owned_read.takeSnapshot(allocator);
        return .{
            .allocator = allocator,
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

    pub fn neighbors(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_view.SnapshotNeighborIterator {
        return (try self.view.neighborsCursor(node)) orelse error.InvalidNode;
    }

    pub fn inNeighbors(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_view.SnapshotNeighborIterator {
        return (try self.view.inNeighborsCursor(node)) orelse error.InvalidNode;
    }

    pub fn neighborsMaterialized(self: *const ReadSnapshot, node: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        var it = try self.neighbors(node);
        return it.materialize(allocator);
    }

    pub fn inNeighborsMaterialized(self: *const ReadSnapshot, node: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        var it = try self.inNeighbors(node);
        return it.materialize(allocator);
    }

    pub fn outDegree(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!usize {
        return self.view.outDegree(node);
    }

    pub fn inDegree(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!usize {
        return self.view.inDegree(node);
    }

    pub fn outEdges(self: *const ReadSnapshot, node: types.NodeId) types.GraphError!snapshot_view.SnapshotOutEdgeIterator {
        return (try self.view.outEdges(node)) orelse error.InvalidNode;
    }

    pub fn validate(self: *const ReadSnapshot) types.GraphError!void {
        return validate_mod.validateSnapshot(self.read.core, &self.view);
    }

    pub fn debugValidate(self: *const ReadSnapshot, allocator: std.mem.Allocator) types.GraphError![]types.Violation {
        return validate_mod.debugValidateSnapshot(self.read.core, &self.view, allocator);
    }

    pub fn bfs(self: *const ReadSnapshot, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        return bfs_mod.bfsCaptured(&self.view, start, allocator);
    }

    pub fn dfs(self: *const ReadSnapshot, start: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        return dfs_mod.dfsCaptured(&self.view, start, allocator);
    }

    pub fn hasCycle(self: *const ReadSnapshot, allocator: std.mem.Allocator) types.GraphError!bool {
        return cycle_mod.hasCycleCaptured(&self.view, allocator);
    }
};
