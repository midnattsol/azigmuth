const std = @import("std");
const constants = @import("constants.zig");
const types = @import("types.zig");

/// Concrete internal state of the graph engine.
///
/// Core implementation modules use this type directly so they get explicit
/// fields and editor autocomplete without relying on `anytype` duck typing.
pub const GraphCore = struct {
    allocator: std.mem.Allocator,

    /// Node pages. 256 NodeBuffer per page (~15 KB). Never moved.
    /// Node creation is not part of the concurrent-writer contract.
    node_pages: std.ArrayList([]types.NodeBuffer),

    /// Legacy page lists kept for direct page-allocation tests and single-writer
    /// inspection. Concurrent mutation paths use the atomic page directories.
    edge_blocks_fwd: std.ArrayList([]types.EdgeBlockFwd),
    edge_blocks_rev: std.ArrayList([]types.EdgeBlockRev),
    edge_block_groups: std.ArrayList([]types.EdgeBlockGroup),

    /// Atomically-published page directories for lock-free block/group lookup.
    /// Values are `@intFromPtr(page.ptr)` or 0 when the page is absent.
    edge_blocks_fwd_pages: [constants.MAX_EDGE_BLOCK_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_BLOCK_PAGES,
    edge_blocks_rev_pages: [constants.MAX_EDGE_BLOCK_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_BLOCK_PAGES,
    edge_block_group_pages: [constants.MAX_EDGE_GROUP_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_GROUP_PAGES,

    /// Per-group metadata pages for lock-free retired/free stacks.
    edge_block_group_meta_pages: [constants.MAX_EDGE_GROUP_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_GROUP_PAGES,

    /// Per-block metadata pages for lock-free retired/free stacks.
    edge_blocks_fwd_meta_pages: [constants.MAX_EDGE_BLOCK_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_BLOCK_PAGES,
    edge_blocks_rev_meta_pages: [constants.MAX_EDGE_BLOCK_PAGES]std.atomic.Value(usize) =
        [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** constants.MAX_EDGE_BLOCK_PAGES,

    /// Tagged stack heads: low 32 bits are block index, high 32 bits are tag.
    free_blocks_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    free_blocks_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_blocks_fwd_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_blocks_rev_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),

    /// Tagged stack heads for group retirement/reuse.
    free_groups_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),
    retired_groups_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(constants.END_OF_CHAIN),

    /// Legacy/debug LIFO free lists. The runtime allocator path uses the
    /// lock-free stack heads above; these lists are maintained only when safe
    /// for tests and validation helpers that inspect them directly.
    free_blocks_fwd: std.ArrayList(u32),
    free_blocks_rev: std.ArrayList(u32),
    free_groups: std.ArrayList(u32),

    /// Legacy/debug retired blocks. Runtime retirement always uses the
    /// lock-free retired stack heads above; these lists are maintained only
    /// when safe for tests and validation helpers that inspect them directly.
    retired_blocks_fwd: std.ArrayList(types.RetiredBlock),
    retired_blocks_rev: std.ArrayList(types.RetiredBlock),

    /// Repair debt queues — node indices below occupancy threshold.
    /// These are best-effort single-writer/debug queues. Concurrent writers
    /// publish `needs_repair_*` flags in NodeAdj; `repairBudgeted` scans those
    /// flags so the queue is not on the concurrent-writer correctness path.
    repair_fwd: std.ArrayList(u32),
    repair_rev: std.ArrayList(u32),

    /// Total number of nodes that have been created.
    /// Phase 1 note: non-atomic.  addNode is single-writer only;
    /// concurrent readers must not observe a node_count increase
    /// before the backing page is visible.  Phase 5 will make this
    /// atomic and publish node pages via the same lock-free directory
    /// mechanism used for edge blocks.
    node_count: u32 = 0,

    /// Monotonic counters — total blocks/groups ever allocated.
    block_fwd_count: u32 = 0,
    block_rev_count: u32 = 0,
    group_count: u32 = 0,

    /// Number of writer mutations currently executing.
    active_writers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Debug ArrayLists are disabled permanently once overlapping writers are
    /// observed; lock-free stacks remain authoritative in concurrent mode.
    debug_retired_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

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

    /// Most recent safe_epoch for which reclaim already ran. Avoids O(M²)
    /// re-pushing of the retired stack under a long-running reader.
    last_reclaim_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Rotating cursors for findRepairDebtByFlag so repeated scans do not
    /// restart from node 0 every time.
    repair_scan_cursor_fwd: u32 = 0,
    repair_scan_cursor_rev: u32 = 0,
};
