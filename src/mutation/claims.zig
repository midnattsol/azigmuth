const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");

pub const ClaimedAdjacencies = struct {
    source_node: *types.NodeBuffer,
    destination_node: *types.NodeBuffer,
    source_fwd_claimed: bool = false,
    source_rev_claimed: bool = false,
    destination_fwd_claimed: bool = false,
    destination_rev_claimed: bool = false,

    pub fn release(self: *ClaimedAdjacencies) void {
        if (self.destination_rev_claimed) self.destination_node.rev_claim.store(0, .release);
        if (self.destination_fwd_claimed) self.destination_node.fwd_claim.store(0, .release);
        if (self.source_rev_claimed) self.source_node.rev_claim.store(0, .release);
        if (self.source_fwd_claimed) self.source_node.fwd_claim.store(0, .release);
    }

    fn claimNodeFwd(self: *ClaimedAdjacencies, node: *types.NodeBuffer) !void {
        if (node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        if (node == self.source_node) self.source_fwd_claimed = true else self.destination_fwd_claimed = true;
    }

    fn claimNodeRev(self: *ClaimedAdjacencies, node: *types.NodeBuffer) !void {
        if (node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        if (node == self.source_node) self.source_rev_claimed = true else self.destination_rev_claimed = true;
    }
};

pub const ClaimedNodeSides = struct {
    node: *types.NodeBuffer,
    fwd_claimed: bool = false,
    rev_claimed: bool = false,

    pub fn release(self: *ClaimedNodeSides) void {
        if (self.rev_claimed) self.node.rev_claim.store(0, .release);
        if (self.fwd_claimed) self.node.fwd_claim.store(0, .release);
    }

    pub fn ensureFwd(self: *ClaimedNodeSides) !void {
        if (self.fwd_claimed) return;
        if (self.node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        self.fwd_claimed = true;
    }

    pub fn ensureRev(self: *ClaimedNodeSides) !void {
        if (self.rev_claimed) return;
        if (self.node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
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

pub fn tryClaimAdjacencies(source_node: *types.NodeBuffer, destination_node: *types.NodeBuffer, source_index: u32, destination_index: u32) !ClaimedAdjacencies {
    var claims = ClaimedAdjacencies{
        .source_node = source_node,
        .destination_node = destination_node,
    };
    errdefer claims.release();

    if (source_index == destination_index) {
        try claims.claimNodeFwd(source_node);
        try claims.claimNodeRev(source_node);
    } else {
        try claims.claimNodeFwd(source_node);
        try claims.claimNodeRev(destination_node);
    }

    return claims;
}

pub fn tryClaimNodeSides(node: *types.NodeBuffer, want_fwd: bool, want_rev: bool) !ClaimedNodeSides {
    var claims = ClaimedNodeSides{ .node = node };
    errdefer claims.release();
    if (want_fwd) try claims.ensureFwd();
    if (want_rev) try claims.ensureRev();
    return claims;
}

pub fn publishStagedFwd(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishFwd(expected, needs_repair_fwd, new_degree_fwd);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedRev(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_rev: bool, new_degree_rev: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishRev(expected, needs_repair_rev, new_degree_rev);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedBoth(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u22, rev_degree: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishBoth(expected, flags, fwd_degree, rev_degree);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}
