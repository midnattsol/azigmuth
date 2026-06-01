const std = @import("std");
const types = @import("types.zig");

/// Concrete internal state of the graph engine.
///
/// Core implementation modules use this type directly so they get explicit
/// fields and editor autocomplete without relying on `anytype` duck typing.
pub const GraphCore = struct {
    allocator: std.mem.Allocator,

    /// Node pages. 256 NodeBuffer per page (~15 KB). Never moved.
    node_pages: std.ArrayList([]types.NodeBuffer),

    /// Forward edge block pages. 64 EdgeBlockFwd per page (~33 KB).
    edge_blocks_fwd: std.ArrayList([]types.EdgeBlockFwd),

    /// Reverse edge block pages. 64 EdgeBlockRev per page (~17 KB).
    edge_blocks_rev: std.ArrayList([]types.EdgeBlockRev),

    /// Edge block group pages. 128 EdgeBlockGroup per page (~1.5 KB).
    edge_block_groups: std.ArrayList([]types.EdgeBlockGroup),

    /// LIFO free lists — indices of freed blocks/groups ready for reuse.
    free_blocks_fwd: std.ArrayList(u32),
    free_blocks_rev: std.ArrayList(u32),
    free_groups: std.ArrayList(u32),

    /// Retired blocks — copied out during RCU mutations.
    retired_blocks_fwd: std.ArrayList(types.RetiredBlock),
    retired_blocks_rev: std.ArrayList(types.RetiredBlock),

    /// Repair debt queues — node indices below occupancy threshold.
    repair_fwd: std.ArrayList(u32),
    repair_rev: std.ArrayList(u32),

    /// Total number of nodes that have been created.
    node_count: u32 = 0,

    /// Monotonic counters — total blocks/groups ever allocated.
    block_fwd_count: u32 = 0,
    block_rev_count: u32 = 0,
    group_count: u32 = 0,

    /// Global live edge count — atomic for lock-free `edgeCount()`.
    edge_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Global epoch for retired block reclamation.
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Number of readers currently active in any epoch.
    active_readers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};
