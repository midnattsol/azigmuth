const std = @import("std");
const types = @import("../../core/types.zig");

pub const NodeMutationControl = extern struct {
    claim_fwd: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    claim_rev: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    next_local_edge_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn claimFwd(self: *NodeMutationControl) !void {
        if (self.claim_fwd.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
    }

    pub fn claimRev(self: *NodeMutationControl) !void {
        if (self.claim_rev.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
    }

    pub fn releaseFwd(self: *NodeMutationControl) void {
        self.claim_fwd.store(0, .release);
    }

    pub fn releaseRev(self: *NodeMutationControl) void {
        self.claim_rev.store(0, .release);
    }

    pub fn nextEdgeId(self: *NodeMutationControl) types.GraphError!types.EdgeId {
        var expected = self.next_local_edge_id.load(.acquire);
        while (true) {
            if (expected == std.math.maxInt(u32)) return error.EdgeIdExhausted;
            const desired = expected + 1;
            if (self.next_local_edge_id.cmpxchgWeak(expected, desired, .acq_rel, .acquire) == null) {
                return .{ .local = expected };
            }
            expected = self.next_local_edge_id.load(.acquire);
        }
    }

    pub fn loadNextLocalEdgeId(self: *const NodeMutationControl) u32 {
        return self.next_local_edge_id.load(.acquire);
    }

    pub fn storeNextLocalEdgeId(self: *NodeMutationControl, next_edge_id: u32) void {
        self.next_local_edge_id.store(next_edge_id, .monotonic);
    }
};
