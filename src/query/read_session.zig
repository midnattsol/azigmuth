const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const rcu = @import("../concurrency/rcu.zig");
const snapshot_view = @import("snapshot/view.zig");
const neighbor_iterator = @import("neighbor_iterator.zig");
const types = @import("../core/types.zig");

pub const ReadSession = struct {
    core: *graph_core.GraphCore,
    reader_token: rcu.ReaderToken,
    active: bool = true,

    pub fn init(core: *graph_core.GraphCore, reader_token: rcu.ReaderToken) ReadSession {
        return .{ .core = core, .reader_token = reader_token };
    }

    pub fn deinit(self: *ReadSession) void {
        if (!self.active) return;
        rcu.readerExit(self.core, self.reader_token);
        _ = self.core.call_state.fetchSub(1, .acq_rel);
        self.active = false;
    }

    pub fn nodeCount(self: *const ReadSession) u32 {
        return self.core.publishedNodeCount();
    }

    /// Point reads over the live published state, without the O(node_count)
    /// capture a `ReadSnapshot` performs. The session's call guard keeps the
    /// graph open; each iterator additionally pins its own reader epoch.
    pub fn neighbors(self: *const ReadSession, node: types.NodeId) types.GraphError!neighbor_iterator.NeighborIterator {
        return neighbor_iterator.neighbors(self.core, node);
    }

    pub fn inNeighbors(self: *const ReadSession, node: types.NodeId) types.GraphError!neighbor_iterator.NeighborIterator {
        return neighbor_iterator.inNeighbors(self.core, node);
    }

    pub fn outDegree(self: *const ReadSession, node: types.NodeId) types.GraphError!usize {
        return neighbor_iterator.outDegree(self.core, node);
    }

    pub fn inDegree(self: *const ReadSession, node: types.NodeId) types.GraphError!usize {
        return neighbor_iterator.inDegree(self.core, node);
    }

    /// Captures a sealed in-memory graph view.
    pub fn takeSnapshot(self: *const ReadSession, allocator: std.mem.Allocator) !snapshot_view.CapturedGraphView {
        return snapshot_view.captureGraphView(self.core, allocator);
    }
};
