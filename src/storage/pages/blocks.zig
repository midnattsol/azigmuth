//! Edge-block pool: block and sidecar page access (forward/reverse blocks,
//! edge ids, property rows, live counts), the per-side free/retired stacks,
//! span allocation from the frontier, and frontier rollback during reclaim.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("common.zig");
const index_stack = @import("index_stack.zig");

const EMPTY_INDEX = index_stack.EMPTY_INDEX;
const StackKind = index_stack.StackKind;

fn blockReclamationAt(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) *types.ReclamationEntry {
    return common.reclamationEntryAt(
        if (side == .fwd) &graph.edge_blocks_fwd_reclamation_pages else &graph.edge_blocks_rev_reclamation_pages,
        block_idx,
        constants.EDGE_BLOCKS_PER_PAGE,
    );
}

fn stackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => switch (side) {
            .fwd => &graph.free_blocks_fwd_head,
            .rev => &graph.free_blocks_rev_head,
        },
        .retired => switch (side) {
            .fwd => &graph.retired_blocks_fwd_head,
            .rev => &graph.retired_blocks_rev_head,
        },
    };
}

fn stack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) index_stack.LockFreeIndexStack {
    return index_stack.LockFreeIndexStack.init(stackHead(graph, kind, side));
}

fn pushStack(graph: *graph_core.GraphCore, block_idx: u32, comptime kind: StackKind, comptime side: adjacency.AdjSide) void {
    stack(graph, kind, side).push(blockReclamationAt(graph, block_idx, side), block_idx);
}

fn popStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) ?u32 {
    const EntryContext = struct {
        graph: *graph_core.GraphCore,

        pub fn entryAt(self: @This(), block_idx: u32) *types.ReclamationEntry {
            return blockReclamationAt(self.graph, block_idx, side);
        }
    };
    return stack(graph, kind, side).pop(EntryContext{ .graph = graph });
}

fn detachStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) u32 {
    return stack(graph, kind, side).detach();
}

// ── Page access ──────────────────────────────────────────────────────

/// Raw page-pointer lookups for traversal hot loops: iterators cache these
/// per 64-block page so sequential block walks skip the directory entirely.
pub fn edgeBlockPageRaw(graph: *const graph_core.GraphCore, page_idx: u32, comptime side: adjacency.AdjSide) usize {
    return switch (side) {
        .fwd => graph.edge_blocks_fwd_pages.load(page_idx),
        .rev => graph.edge_blocks_rev_pages.load(page_idx),
    };
}

pub fn blockAlivePageRaw(graph: *const graph_core.GraphCore, page_idx: u32, comptime side: adjacency.AdjSide) usize {
    return switch (side) {
        .fwd => graph.edge_blocks_fwd_alive_pages.load(page_idx),
        .rev => graph.edge_blocks_rev_alive_pages.load(page_idx),
    };
}

pub fn edgeBlockFwdIdsPageRaw(graph: *const graph_core.GraphCore, page_idx: u32) usize {
    return graph.edge_blocks_fwd_id_pages.load(page_idx);
}

pub fn edgeBlockFwdPropsPageRaw(graph: *const graph_core.GraphCore, page_idx: u32) usize {
    return graph.edge_blocks_fwd_prop_pages.load(page_idx);
}

/// Returns mutable access to one forward edge block.
pub fn edgeBlockFwdAt(graph: *graph_core.GraphCore, block_idx: u32) *types.EdgeBlockFwd {
    return common.pageEntryAt(types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one forward edge block.
pub fn edgeBlockFwdAtConst(graph: *const graph_core.GraphCore, block_idx: u32) *const types.EdgeBlockFwd {
    return common.pageEntryAtConst(types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one forward edge-id block.
pub fn edgeBlockFwdIdsAt(graph: *graph_core.GraphCore, block_idx: u32) *types.EdgeBlockFwdIds {
    return common.pageEntryAt(types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one forward edge-id block.
pub fn edgeBlockFwdIdsAtConst(graph: *const graph_core.GraphCore, block_idx: u32) *const types.EdgeBlockFwdIds {
    return common.pageEntryAtConst(types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one forward property-row sidecar block.
pub fn edgeBlockFwdPropsAt(graph: *graph_core.GraphCore, block_idx: u32) *types.EdgeBlockFwdProps {
    return common.pageEntryAt(types.EdgeBlockFwdProps, &graph.edge_blocks_fwd_prop_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one forward property-row sidecar block.
pub fn edgeBlockFwdPropsAtConst(graph: *const graph_core.GraphCore, block_idx: u32) *const types.EdgeBlockFwdProps {
    return common.pageEntryAtConst(types.EdgeBlockFwdProps, &graph.edge_blocks_fwd_prop_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one reverse edge block.
pub fn edgeBlockRevAt(graph: *graph_core.GraphCore, block_idx: u32) *types.EdgeBlockRev {
    return common.pageEntryAt(types.EdgeBlockRev, &graph.edge_blocks_rev_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one reverse edge block.
pub fn edgeBlockRevAtConst(graph: *const graph_core.GraphCore, block_idx: u32) *const types.EdgeBlockRev {
    return common.pageEntryAtConst(types.EdgeBlockRev, &graph.edge_blocks_rev_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one edge block on the requested side.
pub fn edgeBlockAt(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *types.EdgeBlockFwd,
    .rev => *types.EdgeBlockRev,
} {
    return switch (side) {
        .fwd => edgeBlockFwdAt(graph, block_idx),
        .rev => edgeBlockRevAt(graph, block_idx),
    };
}

/// Returns read-only access to one edge block on the requested side.
pub fn edgeBlockAtConst(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *const types.EdgeBlockFwd,
    .rev => *const types.EdgeBlockRev,
} {
    return switch (side) {
        .fwd => edgeBlockFwdAtConst(graph, block_idx),
        .rev => edgeBlockRevAtConst(graph, block_idx),
    };
}

fn ensureBlockPage(graph: *graph_core.GraphCore, page_idx: u32, comptime side: adjacency.AdjSide) !void {
    switch (side) {
        .fwd => {
            _ = try common.ensurePage(graph, types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
            if (graph.multigraph_enabled) _ = try common.ensurePage(graph, types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
            if (graph.edge_properties_enabled) _ = try common.ensurePage(graph, types.EdgeBlockFwdProps, &graph.edge_blocks_fwd_prop_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
            _ = try common.ensureReclamationPage(graph, &graph.edge_blocks_fwd_reclamation_pages, page_idx);
            _ = try common.ensurePage(graph, u8, &graph.edge_blocks_fwd_alive_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
        },
        .rev => {
            _ = try common.ensurePage(graph, types.EdgeBlockRev, &graph.edge_blocks_rev_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
            _ = try common.ensureReclamationPage(graph, &graph.edge_blocks_rev_reclamation_pages, page_idx);
            _ = try common.ensurePage(graph, u8, &graph.edge_blocks_rev_alive_pages, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
        },
    }
}

// ── Live counts ──────────────────────────────────────────────────────

/// Live-count sidecar access. The count is published together with the block
/// under the same RCU discipline: blocks are immutable once published, so the
/// sidecar entry of a published block never changes either.
pub fn blockAliveCountPtr(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) *u8 {
    return common.pageEntryAt(u8, if (side == .fwd) &graph.edge_blocks_fwd_alive_pages else &graph.edge_blocks_rev_alive_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

pub fn blockAliveCount(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) u7 {
    const entry = common.pageEntryAtConst(u8, if (side == .fwd) &graph.edge_blocks_fwd_alive_pages else &graph.edge_blocks_rev_alive_pages, block_idx, constants.EDGE_BLOCKS_PER_PAGE);
    return @intCast(entry.*);
}

pub fn setBlockAliveCount(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide, alive_count: u7) void {
    blockAliveCountPtr(graph, block_idx, side).* = alive_count;
}

/// Dense-storage block reset: only the live count needs clearing. Slots
/// beyond [0, alive) — including the id/property sidecars — are never read
/// under the dense contract, so the 0.5–1 KB per-block memset is skipped.
fn resetBlock(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) void {
    setBlockAliveCount(graph, block_idx, side, 0);
}

fn zeroBlockRange(graph: *graph_core.GraphCore, first_block_idx: u32, end_block_idx: u32, comptime side: adjacency.AdjSide) void {
    for (first_block_idx..end_block_idx) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        resetBlock(graph, block_idx, side);
    }
}

// ── Allocation ───────────────────────────────────────────────────────

fn reserveFreshBlockSpan(graph: *graph_core.GraphCore, span_count: u32, comptime side: adjacency.AdjSide) !?struct { first_block_idx: u32, end_block_idx: u32 } {
    const first_block_idx = switch (side) {
        .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
        .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
    };
    const end_block_idx = std.math.add(u32, first_block_idx, span_count) catch return error.OutOfMemory;

    try ensureBlockCapacity(graph, end_block_idx, side);
    const actual_frontier = switch (side) {
        .fwd => @cmpxchgWeak(u32, &graph.block_fwd_count, first_block_idx, end_block_idx, .acq_rel, .acquire),
        .rev => @cmpxchgWeak(u32, &graph.block_rev_count, first_block_idx, end_block_idx, .acq_rel, .acquire),
    };
    if (actual_frontier != null) return null;

    return .{ .first_block_idx = first_block_idx, .end_block_idx = end_block_idx };
}

fn allocFreshBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    while (true) {
        const block_idx = switch (side) {
            .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
            .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
        };
        const page_idx = common.pageOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE);

        try ensureBlockPage(graph, page_idx, side);
        switch (side) {
            .fwd => if (@cmpxchgWeak(u32, &graph.block_fwd_count, block_idx, block_idx + 1, .acq_rel, .acquire) == null) return block_idx,
            .rev => if (@cmpxchgWeak(u32, &graph.block_rev_count, block_idx, block_idx + 1, .acq_rel, .acquire) == null) return block_idx,
        }
    }
}

/// Reserves a fresh contiguous span of blocks and zero-initializes it.
pub fn allocFreshBlockSpan(graph: *graph_core.GraphCore, span_count: u32, comptime side: adjacency.AdjSide) !u32 {
    std.debug.assert(span_count > 0);

    while (true) {
        const reservation = (try reserveFreshBlockSpan(graph, span_count, side)) orelse continue;
        zeroBlockRange(graph, reservation.first_block_idx, reservation.end_block_idx, side);
        return reservation.first_block_idx;
    }
}

/// Like allocFreshBlockSpan but without zero-initialization. Safe when the
/// caller fully writes the dense prefix [0, alive) of every block (plus its
/// sidecars and live count) before publish; stale bytes beyond the live
/// count are never read under the dense-storage contract.
pub fn allocFreshBlockSpanRaw(graph: *graph_core.GraphCore, span_count: u32, comptime side: adjacency.AdjSide) !u32 {
    std.debug.assert(span_count > 0);

    while (true) {
        const reservation = (try reserveFreshBlockSpan(graph, span_count, side)) orelse continue;
        return reservation.first_block_idx;
    }
}

/// Ensures backing pages exist for blocks up to `required_block_count` on one side.
pub fn ensureBlockCapacity(graph: *graph_core.GraphCore, required_block_count: u32, comptime side: adjacency.AdjSide) !void {
    if (required_block_count == 0) return;

    const last_page_idx = common.pageOf(required_block_count - 1, constants.EDGE_BLOCKS_PER_PAGE);
    // Frontier invariant: every page covering [0, block_count) was ensured
    // when those blocks were allocated, so only the new tail pages need work
    // — span allocation must not walk the whole page directory.
    const frontier = switch (side) {
        .fwd => graph.loadBlockFwdCount(),
        .rev => graph.loadBlockRevCount(),
    };
    var page_idx: u32 = common.pageOf(frontier, constants.EDGE_BLOCKS_PER_PAGE);
    while (page_idx <= last_page_idx) : (page_idx += 1) {
        try ensureBlockPage(graph, page_idx, side);
    }
}

/// Allocates one zeroed block, reusing the free stack when available.
///
/// Last-resort path: when fresh block space is exhausted (structural index
/// limit or allocator failure), one reclaim pass segments before giving up so
/// that epoch-safe retired blocks are preferred over a hard failure. This is
/// not hidden periodic maintenance — it only triggers when the alternative
/// is returning error.OutOfMemory.
pub fn allocBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    if (popStack(graph, .free, side)) |block_idx| {
        resetBlock(graph, block_idx, side);
        return block_idx;
    }

    return allocFreshBlock(graph, side) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const block_idx = popStack(graph, .free, side) orelse return err;
            resetBlock(graph, block_idx, side);
            return block_idx;
        },
    };
}

// ── Free / retire / reclaim ──────────────────────────────────────────

/// Returns one block to the per-side free stack.
pub fn freeBlock(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) void {
    pushStack(graph, block_idx, .free, side);
}

/// Moves one block to the retired stack with its retirement epoch recorded.
pub fn retireBlock(graph: *graph_core.GraphCore, block_idx: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
    const entry = blockReclamationAt(graph, block_idx, side);
    entry.retired_epoch.store(epoch, .release);
    pushStack(graph, block_idx, .retired, side);
}

fn requeueOrFreeRetiredBlock(graph: *graph_core.GraphCore, block_idx: u32, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    const entry = blockReclamationAt(graph, block_idx, side);
    const retired_epoch = entry.retired_epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeBlock(graph, block_idx, side);
    } else {
        pushStack(graph, block_idx, .retired, side);
    }
}

/// Reclaims retired blocks whose epoch is now safe for reuse.
pub fn reclaimRetired(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var block_idx = detachStack(graph, .retired, side);
    while (block_idx != EMPTY_INDEX) {
        const entry = blockReclamationAt(graph, block_idx, side);
        const next = entry.next.load(.acquire);
        requeueOrFreeRetiredBlock(graph, block_idx, safe_epoch, side);
        block_idx = next;
    }

    rollbackFreeFrontier(graph, side);
}

/// Frontier recycling: fresh contiguous spans (segment coalescing, dense repack)
/// can only come from the allocation frontier, so remove-heavy churn grows
/// the block pool while the free stack swells with scattered singles. During
/// explicit reclaim, drain the free stack and roll the frontier counter back
/// over any suffix of free blocks ending at the frontier — those indices
/// become fresh span space again, bounding pool growth under churn.
///
/// Best-effort: needs a transient sort buffer; on OutOfMemory the stack is
/// left untouched (reclaim stays infallible). Safe against concurrent
/// allocators: rolled-back blocks are held privately (detached from every
/// stack) with their live counts reset BEFORE the frontier CAS, and a
/// concurrent fresh reservation racing the CAS simply retries on its own
/// failed compare-exchange.
fn rollbackFreeFrontier(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) void {
    var head = detachStack(graph, .free, side);
    if (head == EMPTY_INDEX) return;

    var free_blocks: std.ArrayList(u32) = .empty;
    defer free_blocks.deinit(graph.allocator);

    while (head != EMPTY_INDEX) {
        const next = blockReclamationAt(graph, head, side).next.load(.acquire);
        free_blocks.append(graph.allocator, head) catch {
            // Out of memory: push everything collected (and the rest of the
            // chain) straight back and bail.
            pushStack(graph, head, .free, side);
            var rest = next;
            while (rest != EMPTY_INDEX) {
                const rest_next = blockReclamationAt(graph, rest, side).next.load(.acquire);
                pushStack(graph, rest, .free, side);
                rest = rest_next;
            }
            for (free_blocks.items) |block_idx| pushStack(graph, block_idx, .free, side);
            return;
        };
        head = next;
    }

    std.sort.pdq(u32, free_blocks.items, {}, std.sort.asc(u32));

    while (true) {
        const frontier = switch (side) {
            .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
            .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
        };

        // Longest suffix of the sorted free list that ends exactly at the
        // frontier: free_blocks[keep..] == [new_frontier, frontier).
        var keep = free_blocks.items.len;
        var expected = frontier;
        while (keep > 0 and free_blocks.items[keep - 1] == expected - 1) {
            keep -= 1;
            expected -= 1;
        }
        if (keep == free_blocks.items.len) break;

        // Fresh allocations skip zero-init, so recycled frontier blocks must
        // present zeroed live counts before they become reachable again.
        for (free_blocks.items[keep..]) |block_idx| {
            setBlockAliveCount(graph, block_idx, side, 0);
        }

        const cas_result = switch (side) {
            .fwd => @cmpxchgStrong(u32, &graph.block_fwd_count, frontier, expected, .acq_rel, .acquire),
            .rev => @cmpxchgStrong(u32, &graph.block_rev_count, frontier, expected, .acq_rel, .acquire),
        };
        if (cas_result == null) {
            free_blocks.items.len = keep;
            break;
        }
        // Frontier moved (concurrent fresh allocation): retry against the
        // new frontier — our suffix may no longer touch it.
    }

    for (free_blocks.items) |block_idx| pushStack(graph, block_idx, .free, side);
}
