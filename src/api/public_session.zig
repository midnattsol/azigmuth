//! Public `ReadSession` handle — heap-allocated opaque session for cheap
//! point reads over the live published state. Unlike `ReadSnapshot`, opening
//! a session does NOT capture the whole graph (no O(node_count) work): each
//! query reads the current published adjacency under RCU. Reads through the
//! same session may therefore observe newer published states as writers make
//! progress; use `ReadSnapshot` when a fixed view is required.

const std = @import("std");
const internal = @import("../graph.zig");

const SessionState = struct {
    session: internal.ReadSession,
    allocator: std.mem.Allocator,
};

pub const ReadSession = opaque {
    fn inner(self: *ReadSession) *SessionState {
        return @ptrCast(@alignCast(self));
    }

    fn innerConst(self: *const ReadSession) *const SessionState {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *ReadSession) void {
        const state = self.inner();
        const allocator = state.allocator;
        state.session.deinit();
        allocator.destroy(state);
    }

    pub fn nodeCount(self: *const ReadSession) usize {
        return self.innerConst().session.nodeCount();
    }

    pub fn neighbors(self: *const ReadSession, node: internal.NodeId) internal.GraphError!internal.NeighborIterator {
        return self.innerConst().session.neighbors(node);
    }

    pub fn inNeighbors(self: *const ReadSession, node: internal.NodeId) internal.GraphError!internal.NeighborIterator {
        return self.innerConst().session.inNeighbors(node);
    }

    pub fn outDegree(self: *const ReadSession, node: internal.NodeId) internal.GraphError!usize {
        return self.innerConst().session.outDegree(node);
    }

    pub fn inDegree(self: *const ReadSession, node: internal.NodeId) internal.GraphError!usize {
        return self.innerConst().session.inDegree(node);
    }
};

pub fn create(graph: *const internal.Graph, allocator: std.mem.Allocator) internal.GraphError!*ReadSession {
    const state = try allocator.create(SessionState);
    errdefer allocator.destroy(state);
    state.* = .{
        .session = try graph.beginReadSession(),
        .allocator = allocator,
    };
    return @ptrCast(state);
}
