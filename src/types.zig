const std = @import("std");

// ── Basic types ──────────────────────────────────────────────────────

/// Opaque node identifier. Flat u32 index; internally resolved to
/// (page = index >> 8, slot = index & 255).
pub const NodeId = struct { index: u32 };

pub const GraphError = error{
    OutOfMemory,
    InvalidNode,
    EdgeAlreadyExists,
    CorruptGraph,
    ConcurrentMutation,
    UnsupportedOperation,
    RepairRequired,
};

/// Per-node boolean flags. Backed by u32.
pub const NodeFlags = packed struct(u32) {
    needs_repair_fwd: bool,
    needs_repair_rev: bool,
    removed: bool,
    _reserved: u29 = 0,
};

/// Edge-level boolean flags. 16 bits packed alongside relation and destination.
/// Unused in v0; reserved for future features (pinned, hidden, traversed...).
pub const EdgeFlags = packed struct(u16) {
    _unused: u16 = 0,
};

/// A single directed edge. 8 bytes: 4-byte destination + 2-byte relation label
/// + 2-byte packed flags. Larger properties (weights, timestamps) go in
/// external columnar arrays keyed by (source, destination) pair.
pub const Edge = packed struct {
    destination: u32,
    relation: u16,
    flags: EdgeFlags,
};

// ── Per-node adjacency descriptor ────────────────────────────────────

/// Describes where the node's forward and reverse edge blocks live,
/// how many there are, and whether they are contiguous or grouped.
/// 28 bytes, naturally aligned (no padding).
pub const NodeAdj = extern struct {
    first_block_fwd: u32,
    block_count_fwd: u16,
    group_count_fwd: u16,
    first_group_fwd: u32,

    first_block_rev: u32,
    block_count_rev: u16,
    group_count_rev: u16,
    first_group_rev: u32,

    flags: NodeFlags,
};

/// RCU double-buffer for adjacency headers.
/// Readers consume `publishedAdj()` with no locks.
/// Writers copy published → staging, mutate staging, then publish it.
pub const NodeBuffer = extern struct {
    /// Published adjacency buffer index (0 or 1).
    /// Stored as u8 because Zig atomics require byte-sized integers.
    published_adj_index_raw: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Per-node claim bits: forward adjacency (for writers mutating outgoing edges).
    fwd_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Per-node claim bits: reverse adjacency (for writers mutating incoming edges).
    rev_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Double-buffered adjacency headers.
    adj_buffers: [2]NodeAdj,

    /// Cached forward / reverse degree.  Updated under the writer claim
    /// immediately after publishing so that `outDegree` / `inDegree` are
    /// O(1) for nodes with fewer than 65535 edges.  The sentinel 0xFFFF
    /// signals overflow; the query layer falls back to an O(B) scan.
    degree_fwd: u16 = 0,
    degree_rev: u16 = 0,

    pub fn loadPublishedAdjIndex(self: *const NodeBuffer) u1 {
        const raw = self.published_adj_index_raw.load(.acquire);
        std.debug.assert(raw <= 1);
        return @intCast(raw);
    }

    pub fn storePublishedAdjIndex(self: *NodeBuffer, index: u1) void {
        self.published_adj_index_raw.store(@as(u8, index), .release);
    }

    pub fn publishedAdj(self: *const NodeBuffer) NodeAdj {
        const published_index = self.loadPublishedAdjIndex();
        return self.adj_buffers[published_index];
    }

    pub fn stagingAdj(self: *NodeBuffer) *NodeAdj {
        const published_index = self.loadPublishedAdjIndex();
        const staging_index: u1 = 1 - published_index;
        return &self.adj_buffers[staging_index];
    }

    pub fn copyPublishedToStaging(self: *NodeBuffer) void {
        const published_index = self.loadPublishedAdjIndex();
        const staging_index: u1 = 1 - published_index;
        self.adj_buffers[staging_index] = self.adj_buffers[published_index];
    }

    pub fn publishStagingAdj(self: *NodeBuffer) void {
        const published_index = self.loadPublishedAdjIndex();
        const staging_index: u1 = 1 - published_index;
        self.storePublishedAdjIndex(staging_index);
    }
};

// ── Edge blocks ──────────────────────────────────────────────────────

/// 64 outgoing edges (520 bytes). Dense storage: live entries occupy
/// slots [0, live_count) with no holes. `mask = denseMask(live_count)`.
/// Sorted by destination for binary-search lookup. Iteration via `@ctz(mask)` +
/// `mask &= mask - 1` with zero branches.
pub const EdgeBlockFwd = struct {
    mask: u64,
    edges: [64]Edge,
};

/// 64 incoming source node IDs (264 bytes). Same mask logic as
/// EdgeBlockFwd, but payload is u32 (half the size) — reverse adjacency
/// only needs the source, not relation or flags.
pub const EdgeBlockRev = struct {
    mask: u64,
    sources: [64]u32,
};

// ── Contiguous edge block group ──────────────────────────────────────

/// A chainable span of physically contiguous edge blocks. 0xFFFF_FFFF = end.
/// 12 bytes aligned: avoids cache-line splits during chain traversal.
/// Nodes with contiguous blocks use `group_count_* = 0` (fast path).
pub const EdgeBlockGroup = struct {
    start: u32,
    next: u32,
    count: u16,
    _pad: u16 = 0,
};

/// Per-block metadata used by lock-free retired/free stacks.
/// Stored out-of-line so retiring a published block never mutates memory that
/// an active reader may still be scanning.
pub const BlockMeta = struct {
    next: std.atomic.Value(u32),
    epoch: std.atomic.Value(u64),
};

/// Tracks a retired block index and the epoch when it was retired.
pub const RetiredBlock = struct {
    block: u32,
    epoch: u64,
};

/// Validation violation type. Returned by `debugValidate`.
pub const Violation = union(enum) {
    degree_mismatch: struct { node: u32, expected: u32, actual: u32 },
    occupancy_below_threshold: struct { node: u32, block: u32, occupancy: u32 },
    mask_bit_out_of_range: struct { node: u32, block: u32 },
    invalid_dst: struct { node: u32, block: u32, slot: u32, dst: u32 },
    forward_reverse_mismatch: struct { node: u32, dst: u32 },
    unsorted_block: struct { node: u32, block: u32, slot: u32 },
    blockgroup_chain_cycle: struct { node: u32, group: u32 },
    blockgroup_overlap: struct { node: u32, group_a: u32, group_b: u32 },
    block_double_owned: struct { block: u32 },
    block_orphaned_in_free_list: struct { block: u32 },
    repair_debt_invalid_node: struct { entry: u32 },
    edge_count_mismatch: struct { expected: u64, actual: u64 },
    retired_block_reachable: struct { block: u32, node: u32 },
};
