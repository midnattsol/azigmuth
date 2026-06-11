const std = @import("std");
const node_meta = @import("../../../storage/node/meta.zig");
const types = @import("../../../core/types.zig");
const common = @import("../../common.zig");

pub const RelatedNode = struct {
    node_index: u32,
    node_meta: *node_meta.NodeMeta,
    /// Destinations hold their reverse claim so adjacent removeNode calls
    /// serialize; predecessor forward updates are claim-free per RFC §5.3.
    claims: common.ClaimedNodeSides,
    fwd_degree_delta: u22,
    rev_degree_delta: u22,
};

pub const RemovalScan = struct {
    forward_destinations: std.ArrayList(u32) = .empty,
    reverse_sources: std.ArrayList(u32) = .empty,
    self_edge_count: u32 = 0,
    visible_forward: u32 = 0,
    visible_incoming: u32 = 0,

    pub fn deinit(self: *RemovalScan, allocator: std.mem.Allocator) void {
        self.forward_destinations.deinit(allocator);
        self.reverse_sources.deinit(allocator);
    }
};

pub const RemoveCounts = struct {
    predecessors: u32 = 0,
    destinations: u32 = 0,
    /// Edge removals actually applied at publish time. Related nodes that
    /// were concurrently removed after the scan are excluded, so the global
    /// edge_count never double-decrements under adjacent removeNode races.
    applied_edge_removals: u64 = 0,
};

pub const RelatedUpdates = struct {
    nodes: std.ArrayList(RelatedNode),
    index: std.AutoHashMap(u32, usize),

    pub fn deinit(self: *RelatedUpdates, allocator: std.mem.Allocator) void {
        var remaining = self.nodes.items.len;
        while (remaining > 0) {
            remaining -= 1;
            self.nodes.items[remaining].claims.release();
        }
        self.nodes.deinit(allocator);
        self.index.deinit();
    }
};
