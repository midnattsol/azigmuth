const std = @import("std");
const constants = @import("constants.zig");
const radix_directory = @import("../storage/radix_directory.zig");
const node_tiny = @import("../storage/node/tiny.zig");
const types = @import("types.zig");

/// Tracks liveness of one reader token. Stored per graph instance so that
/// independent graphs never contend for (or exhaust) each other's tokens.
pub const TokenLivenessSlot = struct {
    id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

pub const MAX_TRACKED_OVERFLOW_READERS: usize = constants.MAX_TRACKED_OVERFLOW_READERS;
pub const MAX_TOKEN_LIVENESS_SLOTS: usize = constants.MAX_READER_SLOTS + MAX_TRACKED_OVERFLOW_READERS;

/// Concrete internal state of the graph engine.
///
/// Core implementation modules use this type directly so they get explicit
/// fields and editor autocomplete without relying on `anytype` duck typing.
pub const GraphCore = struct {
    pub const NodePageDirectory = radix_directory.RadixDirectory(constants.NODE_DIR.inline_pages, constants.NODE_DIR.l1, constants.NODE_DIR.l2);
    pub const EdgeBlockPageDirectory = radix_directory.RadixDirectory(constants.EDGE_BLOCK_DIR.inline_pages, constants.EDGE_BLOCK_DIR.l1, constants.EDGE_BLOCK_DIR.l2);
    pub const EdgeGroupPageDirectory = radix_directory.RadixDirectory(constants.EDGE_GROUP_DIR.inline_pages, constants.EDGE_GROUP_DIR.l1, constants.EDGE_GROUP_DIR.l2);

    allocator: std.mem.Allocator,

    /// Enables multigraph mode: multiple edges between the same (source,destination)
    /// pair are allowed, and `EdgeId` disambiguates them.
    multigraph_enabled: bool = false,

    /// Enables stable per-edge property rows (see GraphOptions.edge_properties).
    edge_properties_enabled: bool = false,

    /// Atomically-published node metadata pages for lock-free node lookup
    /// during concurrent reads and `addNode` growth.
    node_meta_pages: NodePageDirectory = .{},
    node_published_pages: NodePageDirectory = .{},
    node_hot_pages: NodePageDirectory = .{},
    tiny_fwd_pages: NodePageDirectory = .{},
    tiny_rev_pages: NodePageDirectory = .{},

    /// Per-tiny-slot metadata pages for lock-free retired/free stacks.
    tiny_fwd_meta_pages: NodePageDirectory = .{},
    tiny_rev_meta_pages: NodePageDirectory = .{},

    /// Per-node repair queue membership bitmaps to avoid duplicate queue entries.
    repair_queued_fwd_pages: NodePageDirectory = .{},
    repair_queued_rev_pages: NodePageDirectory = .{},

    /// Atomically-published page directories for lock-free block/group lookup.
    /// Values are `@intFromPtr(page.ptr)` or 0 when the page is absent.
    edge_blocks_fwd_pages: EdgeBlockPageDirectory = .{},
    edge_blocks_rev_pages: EdgeBlockPageDirectory = .{},
    edge_block_group_pages: EdgeGroupPageDirectory = .{},

    /// Per-forward-block edge ID sidecar pages. Same block_idx and lifecycle
    /// as edge_blocks_fwd_pages.
    edge_blocks_fwd_id_pages: EdgeBlockPageDirectory = .{},

    /// Per-forward-block property row sidecar pages (edge_properties mode).
    /// Same block_idx and lifecycle as edge_blocks_fwd_pages.
    edge_blocks_fwd_prop_pages: EdgeBlockPageDirectory = .{},

    /// Per-property-row lifecycle metadata for the lock-free free/retired
    /// row stacks (edge_properties mode). 256 rows per page.
    prop_row_meta_pages: NodePageDirectory = .{},

    /// Per-group metadata pages for lock-free retired/free stacks.
    edge_block_group_meta_pages: EdgeGroupPageDirectory = .{},

    /// Per-block metadata pages for lock-free retired/free stacks.
    edge_blocks_fwd_meta_pages: EdgeBlockPageDirectory = .{},
    edge_blocks_rev_meta_pages: EdgeBlockPageDirectory = .{},

    /// Per-block live-count sidecar pages (u8 each): one 64-byte page covers
    /// a whole block page, keeping counts dense in cache during scans.
    edge_blocks_fwd_live_pages: EdgeBlockPageDirectory = .{},
    edge_blocks_rev_live_pages: EdgeBlockPageDirectory = .{},

    /// Tagged stack heads: low 32 bits are block index, high 32 bits are tag.
    free_blocks_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    free_blocks_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_blocks_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_blocks_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),

    /// Tagged stack heads for property-row reuse (edge_properties mode):
    /// rows of removed edges retire with an epoch and recycle once safe.
    free_prop_rows_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_prop_rows_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),

    /// Tagged stack heads for tiny-slot reuse — same retire/reclaim discipline
    /// as edge blocks so superseded tiny slots return to circulation.
    free_tiny_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    free_tiny_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_tiny_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_tiny_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),

    /// Tagged stack heads for grouped-run retirement/reuse, indexed by
    /// (span_len - 1). Published grouped sides own a contiguous span of up to
    /// MAX_GROUPS_PER_NODE run descriptors.
    free_group_spans_head: [constants.MAX_GROUPS_PER_NODE]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(constants.END_OF_CHAIN)} ** constants.MAX_GROUPS_PER_NODE,
    retired_group_spans_head: [constants.MAX_GROUPS_PER_NODE]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(constants.END_OF_CHAIN)} ** constants.MAX_GROUPS_PER_NODE,

    /// Repair debt queues — node indices below occupancy threshold.
    /// These are best-effort single-writer queues.  Concurrent writers
    /// publish `needs_repair_*` flags in NodeAdj; `repairBudgeted` scans those
    /// flags so the queue is not on the concurrent-writer correctness path.
    repair_fwd: std.ArrayList(u32),
    repair_rev: std.ArrayList(u32),
    repair_queue_lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Total number of nodes that have been published.
    /// Readers load this atomically before dereferencing a node page.
    node_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Monotonic counters — total blocks/groups ever allocated.
    block_fwd_count: u32 = 0,
    block_rev_count: u32 = 0,
    group_count: u32 = 0,
    tiny_fwd_count: u32 = 0,
    tiny_rev_count: u32 = 0,

    /// Monotonic property-row counter. Row 0 is reserved as invalid/unset.
    prop_row_count: u32 = 1,

    /// Number of writer mutations currently executing.
    active_writers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Single active repairBudgeted caller guard.
    active_repairers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Public call state: low 31 bits count active public API calls, high bit
    /// closes the graph to new callers during `deinitChecked`.
    ///
    /// This single atomic state closes the check-then-free race for both
    /// mutations and lightweight reads: callers atomically increment the count
    /// only when the closing bit is clear, and `deinitChecked` atomically sets
    /// the closing bit before checking for active users.
    call_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Global live edge count — atomic for lock-free `edgeCount()`.
    edge_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Global epoch for retired block reclamation.
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Number of readers currently active; kept for diagnostics/tests.
    active_readers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Precise reader epochs. Value 0 means inactive; otherwise stored epoch+1.
    reader_epochs: [constants.MAX_READER_SLOTS]std.atomic.Value(u64) =
        [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** constants.MAX_READER_SLOTS,

    /// Readers that could not acquire an epoch slot. Any overflow reader makes
    /// reclamation conservative until it exits.
    reader_epoch_overflow: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Per-instance reader token liveness pool plus its id counter.
    token_liveness_slots: [MAX_TOKEN_LIVENESS_SLOTS]TokenLivenessSlot =
        [_]TokenLivenessSlot{.{}} ** MAX_TOKEN_LIVENESS_SLOTS,
    next_reader_token_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    /// Most recent safe_epoch for which reclaim already ran. Avoids O(M²)
    /// re-pushing of the retired stack under a long-running reader.
    last_reclaim_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Rotating cursors for repair-debt scans so repeated scans do not
    /// restart from node 0 every time.
    repair_scan_cursor_fwd: u32 = 0,
    repair_scan_cursor_rev: u32 = 0,
    repair_scan_cursor_tombstone: u32 = 0,

    pub const CALL_CLOSING_BIT: u32 = 0x8000_0000;
    pub const CALL_ACTIVE_MASK: u32 = 0x7FFF_FFFF;

    pub inline fn callState(self: *const GraphCore) u32 {
        return self.call_state.load(.acquire);
    }

    pub inline fn activeCallCount(self: *const GraphCore) u32 {
        return self.callState() & CALL_ACTIVE_MASK;
    }

    pub inline fn isClosing(self: *const GraphCore) bool {
        return (self.callState() & CALL_CLOSING_BIT) != 0;
    }

    pub inline fn publishedNodeCount(self: *const GraphCore) u32 {
        return self.node_count.load(.acquire);
    }

    pub inline fn hasNode(self: *const GraphCore, node: types.NodeId) bool {
        return node.index < self.publishedNodeCount();
    }

    // ── Monotonic allocation counters ─────────────────────────────────
    // Written with atomic RMW during allocation; every cross-thread read
    // must go through these acquire loads (a plain read is a data race).

    pub inline fn loadGroupCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.group_count), .acquire);
    }

    pub inline fn loadBlockFwdCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.block_fwd_count), .acquire);
    }

    pub inline fn loadBlockRevCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.block_rev_count), .acquire);
    }

    pub inline fn loadTinyFwdCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.tiny_fwd_count), .acquire);
    }

    pub inline fn loadTinyRevCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.tiny_rev_count), .acquire);
    }

    pub inline fn loadPropRowCount(self: *const GraphCore) u32 {
        return @atomicLoad(u32, @constCast(&self.prop_row_count), .acquire);
    }
};
