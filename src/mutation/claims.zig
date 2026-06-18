const graph_core = @import("../core/graph_core.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_mutation_control = @import("../storage/node/mutation_control.zig");
const types = @import("../core/types.zig");

pub const ClaimedAdjacencies = struct {
    source_mutation_control: *node_mutation_control.NodeMutationControl,
    destination_mutation_control: *node_mutation_control.NodeMutationControl,
    source_fwd_claimed: bool = false,
    source_rev_claimed: bool = false,
    destination_fwd_claimed: bool = false,
    destination_rev_claimed: bool = false,

    pub fn release(self: *ClaimedAdjacencies) void {
        if (self.destination_rev_claimed) self.destination_mutation_control.releaseRev();
        if (self.destination_fwd_claimed) self.destination_mutation_control.releaseFwd();
        if (self.source_rev_claimed) self.source_mutation_control.releaseRev();
        if (self.source_fwd_claimed) self.source_mutation_control.releaseFwd();
    }

    fn claimNodeFwd(self: *ClaimedAdjacencies, mutation_control: *node_mutation_control.NodeMutationControl, is_source: bool) !void {
        try mutation_control.claimFwd();
        if (is_source) self.source_fwd_claimed = true else self.destination_fwd_claimed = true;
    }

    fn claimNodeRev(self: *ClaimedAdjacencies, mutation_control: *node_mutation_control.NodeMutationControl, is_source: bool) !void {
        try mutation_control.claimRev();
        if (is_source) self.source_rev_claimed = true else self.destination_rev_claimed = true;
    }
};

pub const ClaimedNodeSides = struct {
    mutation_control: *node_mutation_control.NodeMutationControl,
    fwd_claimed: bool = false,
    rev_claimed: bool = false,

    pub fn release(self: *ClaimedNodeSides) void {
        if (self.rev_claimed) self.mutation_control.releaseRev();
        if (self.fwd_claimed) self.mutation_control.releaseFwd();
    }

    pub fn ensureFwd(self: *ClaimedNodeSides) !void {
        if (self.fwd_claimed) return;
        try self.mutation_control.claimFwd();
        self.fwd_claimed = true;
    }

    pub fn ensureRev(self: *ClaimedNodeSides) !void {
        if (self.rev_claimed) return;
        try self.mutation_control.claimRev();
        self.rev_claimed = true;
    }
};

pub const WriterGuard = struct {
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

pub fn tryClaimAdjacencies(graph: *graph_core.GraphCore, source_idx: u32, destination_idx: u32) !ClaimedAdjacencies {
    // addNode guarantees mutation-control pages for every published node, so claims take
    // the plain load path instead of the (heavier, fallible) ensure path.
    const source_mutation_control = page_ops.nodeMutationControlAt(graph, .{ .index = source_idx });
    const destination_mutation_control = if (source_idx == destination_idx) source_mutation_control else page_ops.nodeMutationControlAt(graph, .{ .index = destination_idx });
    var claims = ClaimedAdjacencies{
        .source_mutation_control = source_mutation_control,
        .destination_mutation_control = destination_mutation_control,
    };
    errdefer claims.release();
    if (source_idx == destination_idx) {
        try claims.claimNodeFwd(source_mutation_control, true);
        try claims.claimNodeRev(source_mutation_control, true);
    } else {
        try claims.claimNodeFwd(source_mutation_control, true);
        try claims.claimNodeRev(destination_mutation_control, false);
    }
    return claims;
}

pub fn tryClaimNodeSides(graph: *graph_core.GraphCore, node_idx: u32, want_fwd: bool, want_rev: bool) !ClaimedNodeSides {
    var claims = ClaimedNodeSides{ .mutation_control = page_ops.nodeMutationControlAt(graph, .{ .index = node_idx }) };
    errdefer claims.release();
    if (want_fwd) try claims.ensureFwd();
    if (want_rev) try claims.ensureRev();
    return claims;
}
