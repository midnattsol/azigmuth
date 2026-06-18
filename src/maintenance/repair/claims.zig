const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_mutation_control = @import("../../storage/node/mutation_control.zig");
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

pub fn claimNodeAdjacency(mutation_control: *node_mutation_control.NodeMutationControl, comptime side: adjacency.AdjSide) !void {
    switch (side) {
        .fwd => try mutation_control.claimFwd(),
        .rev => try mutation_control.claimRev(),
    }
}

pub fn releaseNodeAdjacency(mutation_control: *node_mutation_control.NodeMutationControl, comptime side: adjacency.AdjSide) void {
    switch (side) {
        .fwd => mutation_control.releaseFwd(),
        .rev => mutation_control.releaseRev(),
    }
}

pub fn claimNodeForPublish(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    const mutation_control = try page_ops.ensureNodeMutationControlAt(graph, node);
    try claimNodeAdjacency(mutation_control, .fwd);
    errdefer releaseNodeAdjacency(mutation_control, .fwd);
    try claimNodeAdjacency(mutation_control, .rev);
}

pub fn releaseNodeForPublish(graph: *graph_core.GraphCore, node: types.NodeId) void {
    const mutation_control = page_ops.nodeMutationControlAt(graph, node);
    releaseNodeAdjacency(mutation_control, .rev);
    releaseNodeAdjacency(mutation_control, .fwd);
}
