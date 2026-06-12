const graph_core = @import("../core/graph_core.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_hot = @import("../storage/node/hot.zig");
const types = @import("../core/types.zig");

pub const ClaimedAdjacencies = struct {
    source_hot: *node_hot.NodeHot,
    destination_hot: *node_hot.NodeHot,
    source_fwd_claimed: bool = false,
    source_rev_claimed: bool = false,
    destination_fwd_claimed: bool = false,
    destination_rev_claimed: bool = false,

    pub fn release(self: *ClaimedAdjacencies) void {
        if (self.destination_rev_claimed) self.destination_hot.releaseRev();
        if (self.destination_fwd_claimed) self.destination_hot.releaseFwd();
        if (self.source_rev_claimed) self.source_hot.releaseRev();
        if (self.source_fwd_claimed) self.source_hot.releaseFwd();
    }

    fn claimNodeFwd(self: *ClaimedAdjacencies, hot: *node_hot.NodeHot, is_source: bool) !void {
        try hot.claimFwd();
        if (is_source) self.source_fwd_claimed = true else self.destination_fwd_claimed = true;
    }

    fn claimNodeRev(self: *ClaimedAdjacencies, hot: *node_hot.NodeHot, is_source: bool) !void {
        try hot.claimRev();
        if (is_source) self.source_rev_claimed = true else self.destination_rev_claimed = true;
    }
};

pub const ClaimedNodeSides = struct {
    hot: *node_hot.NodeHot,
    fwd_claimed: bool = false,
    rev_claimed: bool = false,

    pub fn release(self: *ClaimedNodeSides) void {
        if (self.rev_claimed) self.hot.releaseRev();
        if (self.fwd_claimed) self.hot.releaseFwd();
    }

    pub fn ensureFwd(self: *ClaimedNodeSides) !void {
        if (self.fwd_claimed) return;
        try self.hot.claimFwd();
        self.fwd_claimed = true;
    }

    pub fn ensureRev(self: *ClaimedNodeSides) !void {
        if (self.rev_claimed) return;
        try self.hot.claimRev();
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
    // addNode guarantees hot pages for every published node, so claims take
    // the plain load path instead of the (heavier, fallible) ensure path.
    const source_hot = page_ops.nodeHotAt(graph, .{ .index = source_idx });
    const destination_hot = if (source_idx == destination_idx) source_hot else page_ops.nodeHotAt(graph, .{ .index = destination_idx });
    var claims = ClaimedAdjacencies{
        .source_hot = source_hot,
        .destination_hot = destination_hot,
    };
    errdefer claims.release();
    if (source_idx == destination_idx) {
        try claims.claimNodeFwd(source_hot, true);
        try claims.claimNodeRev(source_hot, true);
    } else {
        try claims.claimNodeFwd(source_hot, true);
        try claims.claimNodeRev(destination_hot, false);
    }
    return claims;
}

pub fn tryClaimNodeSides(graph: *graph_core.GraphCore, node_idx: u32, want_fwd: bool, want_rev: bool) !ClaimedNodeSides {
    var claims = ClaimedNodeSides{ .hot = page_ops.nodeHotAt(graph, .{ .index = node_idx }) };
    errdefer claims.release();
    if (want_fwd) try claims.ensureFwd();
    if (want_rev) try claims.ensureRev();
    return claims;
}
