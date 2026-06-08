//! Public `ReadSnapshot` handle — heap-allocated opaque snapshot captured from a
//! live graph. It owns the copied logical node view and keeps the originating
//! read guard alive until `deinit()`.

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

    pub fn neighborsMaterialized(self: *const ReadSnapshot, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        return self.innerConst().neighborsMaterialized(node, allocator);
    }

    pub fn inNeighborsMaterialized(self: *const ReadSnapshot, node: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        return self.innerConst().inNeighborsMaterialized(node, allocator);
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

    pub fn debugValidate(self: *const ReadSnapshot, allocator: std.mem.Allocator) internal.GraphError![]internal.Violation {
        return self.innerConst().debugValidate(allocator);
    }

    pub fn bfs(self: *const ReadSnapshot, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        return self.innerConst().bfs(start, allocator);
    }

    pub fn dfs(self: *const ReadSnapshot, start: internal.NodeId, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        return self.innerConst().dfs(start, allocator);
    }

    pub fn hasCycle(self: *const ReadSnapshot, allocator: std.mem.Allocator) internal.GraphError!bool {
        return self.innerConst().hasCycle(allocator);
    }
};
