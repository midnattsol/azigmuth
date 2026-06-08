const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");

const WriterGuard = struct {
    graph: *graph_core.GraphCore,
    active: bool = true,

    pub fn end(self: *WriterGuard) void {
        if (!self.active) return;
        _ = self.graph.active_writers.fetchSub(1, .acq_rel);
        self.active = false;
    }
};

pub fn beginWriter(graph: *graph_core.GraphCore) WriterGuard {
    _ = graph.active_writers.fetchAdd(1, .acq_rel);
    return .{ .graph = graph };
}

pub fn claimNodeAdjacency(node_buffer: *types.NodeBuffer, comptime side: adjacency.AdjSide) !void {
    const claim = if (side == .fwd) &node_buffer.fwd_claim else &node_buffer.rev_claim;
    if (claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
}

pub fn releaseNodeAdjacency(node_buffer: *types.NodeBuffer, comptime side: adjacency.AdjSide) void {
    const claim = if (side == .fwd) &node_buffer.fwd_claim else &node_buffer.rev_claim;
    claim.store(0, .release);
}

pub fn claimNodeForPublish(node_buffer: *types.NodeBuffer) !void {
    try claimNodeAdjacency(node_buffer, .fwd);
    errdefer releaseNodeAdjacency(node_buffer, .fwd);
    try claimNodeAdjacency(node_buffer, .rev);
}

pub fn releaseNodeForPublish(node_buffer: *types.NodeBuffer) void {
    releaseNodeAdjacency(node_buffer, .rev);
    releaseNodeAdjacency(node_buffer, .fwd);
}
