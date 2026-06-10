const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const rcu = @import("../concurrency/rcu.zig");
const snapshot_view = @import("snapshot/view.zig");

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

    /// Captures a sealed in-memory graph view.
    pub fn takeSnapshot(self: *const ReadSession, allocator: std.mem.Allocator) !snapshot_view.CapturedGraphView {
        return snapshot_view.captureGraphView(self.core, allocator);
    }
};
