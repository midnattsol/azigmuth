const std = @import("std");

// ── Basic types ──────────────────────────────────────────────────────

/// Opaque node identifier. Flat u32 index; internally resolved to
/// (page = index >> 8, slot = index & 255).
pub const NodeId = struct { index: u32 };

/// Opaque edge identifier, local to the source node (not global).
/// 0 is reserved for "empty/unset".
pub const EdgeId = struct { local: u32 };

/// A public edge reference returned by edge-aware iterators.
pub const EdgeRef = struct {
    id: EdgeId,
    destination: u32,
    relation: u16,
    flags: EdgeFlags,
};

/// Options passed at graph creation time.
pub const GraphOptions = struct {
    /// When true, multiple edges between the same (source,destination) pair
    /// are allowed and `EdgeId` disambiguates them.
    multigraph: bool = false,
};

pub const GraphError = error{
    OutOfMemory,
    DegreeLimitReached,
    BlockLimitReached,
    InvalidNode,
    EdgeAlreadyExists,
    CorruptGraph,
    ConcurrentMutation,
    UnsupportedOperation,
    RepairRequired,
    GraphBusy,
};

/// Per-node boolean flags. Backed by u32.
pub const NodeFlags = packed struct(u32) {
    needs_repair_fwd: bool,
    needs_repair_rev: bool,
    removed: bool,
    _reserved: u29 = 0,

    pub fn fromMeta(meta: PublishedMeta) NodeFlags {
        return .{
            .needs_repair_fwd = meta.needs_repair_fwd,
            .needs_repair_rev = meta.needs_repair_rev,
            .removed = meta.removed,
        };
    }
};

pub const PublishedMeta = packed struct(u64) {
    fwd_index: u1 = 0,
    rev_index: u1 = 0,
    needs_repair_fwd: bool = false,
    needs_repair_rev: bool = false,
    removed: bool = false,
    degree_fwd: u22 = 0,
    degree_rev: u22 = 0,
    version: u15 = 0,

    pub fn flags(self: PublishedMeta) NodeFlags {
        return NodeFlags.fromMeta(self);
    }

    pub fn withFlags(self: PublishedMeta, node_flags: NodeFlags) PublishedMeta {
        var next = self;
        next.needs_repair_fwd = node_flags.needs_repair_fwd;
        next.needs_repair_rev = node_flags.needs_repair_rev;
        next.removed = node_flags.removed;
        return next;
    }

    pub fn bumpedVersion(self: PublishedMeta) PublishedMeta {
        var next = self;
        next.version +%= 1;
        return next;
    }
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

// ── Per-side adjacency descriptor ─────────────────────────────────────

/// Forward or reverse side metadata. 12 bytes, 4-byte aligned.
pub const SideAdj = extern struct {
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
};

// ── Combined adjacency snapshot ───────────────────────────────────────

/// Full-node adjacency snapshot for iteration, validation, and bulk operations.
/// Obtained via `NodeBuffer.publishedAdj()` which composes from both sides.
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

// ── Per-node data ─────────────────────────────────────────────────────

/// RCU double-buffer for adjacency headers, per side, with a single atomic
/// publication word that selects both published side buffers and carries the
/// public node flags plus exact logical degree per side.  Readers load one
/// coherent node snapshot from `published_meta`, while writers on disjoint
/// logical sides still publish with per-side claims and CAS.  Exactly 64 bytes.
pub const NodeBuffer = extern struct {
    published_meta: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(PublishedMeta{})),

    /// Per-node writer claims: forward side.
    fwd_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Per-node writer claims: reverse side.
    rev_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fwd_buffers: [2]SideAdj,
    rev_buffers: [2]SideAdj,

    /// Monotonic edge-id counter local to this node, used in multigraph mode.
    /// 0 is reserved for "empty" slot; valid IDs start at 1.
    next_local_edge_id: u32 = 1,

    /// Allocates and returns the next edge ID local to this node.
    pub fn nextEdgeId(self: *NodeBuffer) EdgeId {
        const local = self.next_local_edge_id;
        self.next_local_edge_id += 1;
        return .{ .local = local };
    }

    pub fn loadPublishedMeta(self: *const NodeBuffer) PublishedMeta {
        return @bitCast(self.published_meta.load(.acquire));
    }

    pub fn storePublishedMeta(self: *NodeBuffer, meta: PublishedMeta) void {
        self.published_meta.store(@bitCast(meta), .release);
    }

    pub fn cmpxchgPublishedMeta(self: *NodeBuffer, expected: PublishedMeta, desired: PublishedMeta) ?PublishedMeta {
        const actual = self.published_meta.cmpxchgStrong(@bitCast(expected), @bitCast(desired), .acq_rel, .acquire);
        return if (actual) |raw| @as(PublishedMeta, @bitCast(raw)) else null;
    }

    pub fn publishedFwdFromMeta(self: *const NodeBuffer, meta: PublishedMeta) SideAdj {
        return self.fwd_buffers[meta.fwd_index];
    }

    pub fn publishedRevFromMeta(self: *const NodeBuffer, meta: PublishedMeta) SideAdj {
        return self.rev_buffers[meta.rev_index];
    }

    pub fn publishedFwd(self: *const NodeBuffer) SideAdj {
        return self.publishedFwdFromMeta(self.loadPublishedMeta());
    }

    pub fn publishedRev(self: *const NodeBuffer) SideAdj {
        return self.publishedRevFromMeta(self.loadPublishedMeta());
    }

    pub fn stagingFwd(self: *NodeBuffer, meta: PublishedMeta) *SideAdj {
        return &self.fwd_buffers[1 - meta.fwd_index];
    }

    pub fn stagingRev(self: *NodeBuffer, meta: PublishedMeta) *SideAdj {
        return &self.rev_buffers[1 - meta.rev_index];
    }

    pub fn copyPublishedToStagingFwd(self: *NodeBuffer, meta: PublishedMeta) void {
        self.fwd_buffers[1 - meta.fwd_index] = self.fwd_buffers[meta.fwd_index];
    }

    pub fn copyPublishedToStagingRev(self: *NodeBuffer, meta: PublishedMeta) void {
        self.rev_buffers[1 - meta.rev_index] = self.rev_buffers[meta.rev_index];
    }

    pub fn desiredMetaForPublishFwd(meta: PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u22) PublishedMeta {
        var desired = meta.bumpedVersion();
        desired.fwd_index = 1 - meta.fwd_index;
        desired.needs_repair_fwd = needs_repair_fwd;
        desired.degree_fwd = new_degree_fwd;
        return desired;
    }

    pub fn desiredMetaForPublishRev(meta: PublishedMeta, needs_repair_rev: bool, new_degree_rev: u22) PublishedMeta {
        var desired = meta.bumpedVersion();
        desired.rev_index = 1 - meta.rev_index;
        desired.needs_repair_rev = needs_repair_rev;
        desired.degree_rev = new_degree_rev;
        return desired;
    }

    pub fn desiredMetaForPublishBoth(meta: PublishedMeta, flags: NodeFlags, fwd_degree: u22, rev_degree: u22) PublishedMeta {
        var desired = meta.bumpedVersion();
        desired.fwd_index = 1 - meta.fwd_index;
        desired.rev_index = 1 - meta.rev_index;
        desired.needs_repair_fwd = flags.needs_repair_fwd;
        desired.needs_repair_rev = flags.needs_repair_rev;
        desired.removed = flags.removed;
        desired.degree_fwd = fwd_degree;
        desired.degree_rev = rev_degree;
        return desired;
    }

    /// CAS-friendly forward update: changes `degree_fwd` and `needs_repair_fwd`
    /// WITHOUT touching staging buffers or flipping `fwd_index`/`rev_index`.
    /// Safe to call without `fwd_claim` — the 64-bit CAS on `published_meta`
    /// provides the atomicity.  Intended for paths where only the meta counters
    /// need updating (e.g. predecessor forward-degree decrement in removeNode).
    pub fn desiredMetaForUpdateFwd(meta: PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u22) PublishedMeta {
        var desired = meta.bumpedVersion();
        desired.needs_repair_fwd = needs_repair_fwd;
        desired.degree_fwd = new_degree_fwd;
        return desired;
    }

    /// Composes a full NodeAdj snapshot from the current published sides.
    /// Callers MUST NOT alias the returned value across RCU flips.
    pub fn publishedAdj(self: *const NodeBuffer) NodeAdj {
        while (true) {
            const before = self.loadPublishedMeta();
            const adjacency = self.publishedAdjFromMeta(before);
            const after = self.loadPublishedMeta();
            if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return adjacency;
        }
    }

    pub fn publishedAdjFromMeta(self: *const NodeBuffer, meta: PublishedMeta) NodeAdj {
        const fwd = self.publishedFwdFromMeta(meta);
        const rev = self.publishedRevFromMeta(meta);
        return NodeAdj{
            .first_block_fwd = fwd.first_block,
            .block_count_fwd = fwd.block_count,
            .group_count_fwd = fwd.group_count,
            .first_group_fwd = fwd.first_group,
            .first_block_rev = rev.first_block,
            .block_count_rev = rev.block_count,
            .group_count_rev = rev.group_count,
            .first_group_rev = rev.first_group,
            .flags = meta.flags(),
        };
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

// ── Forward edge ID sidecar ──────────────────────────────────────────

/// Per-forward-block edge ID storage. Shares block_idx and lifecycle with
/// the corresponding EdgeBlockFwd. 256 bytes.
pub const EdgeBlockFwdIds = struct {
    ids: [64]u32,
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
    run_fragmentation_requires_repair: struct { node: u32, group: u32, count: u16 },
    grouped_layout_needs_canonicalization: struct { node: u32, first_group: u32 },
    block_double_owned: struct { block: u32 },
    block_orphaned_in_free_list: struct { block: u32 },
    repair_debt_invalid_node: struct { entry: u32 },
    removed_node_has_outgoing: struct { node: u32 },
    removed_node_has_reverse_residual: struct { node: u32, degree_rev: u22 },
    removed_node_marked_for_repair: struct { node: u32 },
    forward_tombstone_missing_repair_flag: struct { node: u32 },
    edge_count_mismatch: struct { expected: u64, actual: u64 },
    retired_block_reachable: struct { block: u32, node: u32 },
    forward_reverse_count_mismatch: struct { forward_total: u64, reverse_total: u64 },
    unreachable_forward_block: struct { block: u32 },
    unreachable_reverse_block: struct { block: u32 },
    unreachable_group: struct { group: u32 },
    block_count_group_mismatch: struct { node: u32, declared: u16, actual: u16 },
};
