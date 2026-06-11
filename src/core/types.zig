const std = @import("std");
const profile = @import("profile.zig");

/// Edges per adjacency block, fixed per compilation by the storage profile.
const EDGES_PER_BLOCK: usize = profile.active.edges_per_block;

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
    /// Stable property row id (edge_properties mode); 0 = none/disabled.
    property_row: u32 = 0,
};

/// One edge of a batched insertion (see `Graph.addEdges`).
pub const EdgeInput = struct {
    destination: NodeId,
    relation: u16 = 0,
    flags: EdgeFlags = .{},
};

/// Options passed at graph creation time.
pub const GraphOptions = struct {
    /// When true, multiple edges between the same (source,destination) pair
    /// are allowed and `EdgeId` disambiguates them.
    multigraph: bool = false,
    /// When true, every forward edge carries a stable property row id
    /// (`EdgeRef.property_row`) usable as an index into caller-owned
    /// `EdgeColumn(T)` stores. Costs one u32 sidecar per edge slot plus
    /// per-row lifecycle metadata; graphs without properties pay nothing.
    edge_properties: bool = false,
};

pub const NodeRemovalSummary = struct {
    removed_visible_edges: u64,
    related_live_nodes_touched: u32,
    left_repair_debt: bool,
};

/// Visible outcome of an explicit `repairNode` call. `repaired_*` reports
/// whether the side was rebuilt; `preventive_*` marks rebuilds performed
/// without flagged debt (layout hardening so a blocked mutation can retry);
/// `left_repair_debt_*` reports the flag state after the call.
pub const RepairNodeSummary = struct {
    repaired_fwd: bool = false,
    repaired_rev: bool = false,
    preventive_fwd: bool = false,
    preventive_rev: bool = false,
    had_flagged_debt_fwd: bool = false,
    had_flagged_debt_rev: bool = false,
    left_repair_debt_fwd: bool = false,
    left_repair_debt_rev: bool = false,
};

pub const RepairFlushSummary = struct {
    repaired_nodes: usize,
    pass_count: usize,
    remaining_repair_fwd: usize,
    remaining_repair_rev: usize,
    remaining_structural_debt: bool,
};

/// O(1) allocation counters for benchmarking and capacity observability.
/// Counts are monotonic totals of storage ever allocated from fresh space;
/// reuse through the free stacks keeps them flat.
pub const StorageStats = struct {
    blocks_fwd_allocated: u32,
    blocks_rev_allocated: u32,
    groups_allocated: u32,
    tiny_fwd_allocated: u32,
    tiny_rev_allocated: u32,
};

pub const DebtStats = struct {
    live_nodes: usize,
    removed_nodes: usize,

    nodes_with_repair_fwd: usize,
    nodes_with_repair_rev: usize,

    queued_repair_fwd: usize,
    queued_repair_rev: usize,

    grouped_fwd_nodes: usize,
    grouped_rev_nodes: usize,

    estimated_tombstone_fwd_nodes: usize,
};

pub const GraphError = error{
    OutOfMemory,
    DegreeLimitReached,
    EdgeIdExhausted,
    BlockLimitReached,
    InvalidNode,
    EdgeAlreadyExists,
    CorruptGraph,
    ConcurrentMutation,
    UnsupportedOperation,
    RepairRequired,
    GraphBusy,
    Cancelled,
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
    degree_fwd_overflow: bool = false,
    degree_rev_overflow: bool = false,
    degree_fwd: u22 = 0,
    degree_rev: u22 = 0,
    version: u13 = 0,

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

    pub fn withFwdDegree(self: PublishedMeta, degree_fwd: u32) PublishedMeta {
        const inline_limit: u22 = 65535 * 64;
        var next = self;
        if (degree_fwd <= inline_limit) {
            next.degree_fwd = @intCast(degree_fwd);
            next.degree_fwd_overflow = false;
        } else {
            next.degree_fwd = inline_limit;
            next.degree_fwd_overflow = true;
        }
        return next;
    }

    pub fn withRevDegree(self: PublishedMeta, degree_rev: u32) PublishedMeta {
        const inline_limit: u22 = 65535 * 64;
        var next = self;
        if (degree_rev <= inline_limit) {
            next.degree_rev = @intCast(degree_rev);
            next.degree_rev_overflow = false;
        } else {
            next.degree_rev = inline_limit;
            next.degree_rev_overflow = true;
        }
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

/// Forward or reverse side metadata.
pub const SideAdj = extern struct {
    first_block: u32,
    block_count: u32,
    group_count: u16,
    first_group: u32,
};

// ── Combined adjacency snapshot ───────────────────────────────────────

/// Full-node adjacency snapshot for iteration, validation, and bulk operations.
/// Composed on demand from the published NodeMeta + NodePublished pools.
/// Full published adjacency snapshot.
pub const NodeAdj = extern struct {
    first_block_fwd: u32,
    block_count_fwd: u32,
    group_count_fwd: u16,
    first_group_fwd: u32,

    first_block_rev: u32,
    block_count_rev: u32,
    group_count_rev: u16,
    first_group_rev: u32,

    flags: NodeFlags,
};

// ── Per-node data ─────────────────────────────────────────────────────

// ── Edge blocks ──────────────────────────────────────────────────────

/// One block of outgoing edges (profile-sized: 16/32/64 entries; 512 bytes
/// cache-line aligned at the default 64), stored as struct-of-arrays: the
/// contiguous destination array is the only thing neighbor scans touch, and
/// in-block loops vectorize. Dense storage: live entries occupy slots
/// [0, live_count) with no holes, sorted by destination. The live count
/// lives in a per-block u8 sidecar. Access goes through
/// `storage/edge_blocks.zig`.
pub const EdgeBlockFwd = extern struct {
    destinations: [EDGES_PER_BLOCK]u32 align(64),
    relations: [EDGES_PER_BLOCK]u16,
    flags: [EDGES_PER_BLOCK]u16,
};

/// One block of incoming source node IDs (cache-line aligned). Same dense
/// model as EdgeBlockFwd; reverse adjacency only needs the source.
pub const EdgeBlockRev = extern struct {
    sources: [EDGES_PER_BLOCK]u32 align(64),
};

// ── Forward edge ID sidecar ──────────────────────────────────────────

/// Per-forward-block edge ID storage. Shares block_idx and lifecycle with
/// the corresponding EdgeBlockFwd. 256 bytes.
pub const EdgeBlockFwdIds = struct {
    ids: [EDGES_PER_BLOCK]u32,
};

/// Per-forward-block property row sidecar (edge_properties mode). Shares
/// block_idx and lifecycle with the corresponding EdgeBlockFwd. 256 bytes.
/// Row 0 is reserved as invalid/unset.
pub const EdgeBlockFwdProps = struct {
    rows: [EDGES_PER_BLOCK]u32,
};

// ── Contiguous edge block group ──────────────────────────────────────

/// One physically contiguous run of edge blocks within a grouped side.
/// Grouped sides publish `group_count` consecutive descriptors starting at
/// `first_group`. 8 bytes — chain linkage was removed once runs became
/// consecutive spans.
pub const EdgeBlockGroup = struct {
    start: u32,
    count: u32,
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
    invalid_edge_id: struct { node: u32, block: u32, slot: u32, edge_id: u32 },
    invalid_prop_row: struct { node: u32, block: u32, slot: u32, row: u32 },
    duplicate_prop_row: struct { node_a: u32, node_b: u32, row: u32 },
    forward_reverse_mismatch: struct { node: u32, dst: u32 },
    forward_reverse_multiplicity_mismatch: struct { node: u32, dst: u32, forward_count: u32, reverse_count: u32 },
    unsorted_block: struct { node: u32, block: u32, slot: u32 },
    duplicate_edge_id: struct { node: u32, edge_id: u32 },
    edge_id_counter_regressed: struct { node: u32, next_id: u32, max_seen: u32 },
    blockgroup_chain_cycle: struct { node: u32, group: u32 },
    blockgroup_overlap: struct { node: u32, group_a: u32, group_b: u32 },
    run_fragmentation_requires_repair: struct { node: u32, group: u32, count: u32 },
    grouped_layout_needs_canonicalization: struct { node: u32, first_group: u32 },
    block_double_owned: struct { block: u32 },
    block_orphaned_in_free_list: struct { block: u32 },
    repair_debt_invalid_node: struct { entry: u32 },
    removed_node_has_outgoing: struct { node: u32 },
    removed_node_has_reverse_residual: struct { node: u32, degree_rev: u32 },
    removed_node_has_reverse_storage: struct { node: u32, block_count_rev: u32, group_count_rev: u16 },
    removed_node_marked_for_repair: struct { node: u32 },
    forward_tombstone_missing_repair_flag: struct { node: u32 },
    reverse_tombstone_missing_repair_flag: struct { node: u32 },
    edge_count_mismatch: struct { expected: u64, actual: u64 },
    retired_block_reachable: struct { block: u32, node: u32 },
    forward_reverse_count_mismatch: struct { forward_total: u64, reverse_total: u64 },
    unreachable_forward_block: struct { block: u32 },
    unreachable_reverse_block: struct { block: u32 },
    unreachable_group: struct { group: u32 },
    block_count_group_mismatch: struct { node: u32, declared: u32, actual: u32 },
};
