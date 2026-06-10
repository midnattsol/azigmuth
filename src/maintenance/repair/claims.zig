const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_hot = @import("../../storage/node/hot.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
const page_ops = @import("../../storage/page_ops.zig");

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

pub fn claimNodeAdjacency(hot: *node_hot.NodeHot, comptime side: adjacency.AdjSide) !void {
    switch (side) {
        .fwd => try hot.claimFwd(),
        .rev => try hot.claimRev(),
    }
}

pub fn releaseNodeAdjacency(hot: *node_hot.NodeHot, comptime side: adjacency.AdjSide) void {
    switch (side) {
        .fwd => hot.releaseFwd(),
        .rev => hot.releaseRev(),
    }
}

pub fn claimNodeForPublish(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    const hot = try page_ops.ensureNodeHotAt(graph, node);
    try claimNodeAdjacency(hot, .fwd);
    errdefer releaseNodeAdjacency(hot, .fwd);
    try claimNodeAdjacency(hot, .rev);
}

pub fn releaseNodeForPublish(graph: *graph_core.GraphCore, node: types.NodeId) void {
    const hot = page_ops.nodeHotAt(graph, node);
    releaseNodeAdjacency(hot, .rev);
    releaseNodeAdjacency(hot, .fwd);
}
