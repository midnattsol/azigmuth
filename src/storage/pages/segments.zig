//! Edge-block segment descriptor pool: segment page access, slot allocation, and the
//! per-slot-count free/retired stacks (published segmented sides own one
//! contiguous set of segment descriptors, so the slot count must round-trip
//! through the stacks).

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("common.zig");
const index_stack = @import("index_stack.zig");

const EMPTY_INDEX = index_stack.EMPTY_INDEX;
const StackKind = index_stack.StackKind;

fn segmentReclamationAt(graph: *graph_core.GraphCore, segment_idx: u32) *types.ReclamationEntry {
    return common.reclamationEntryAt(&graph.edge_block_segment_reclamation_pages, segment_idx, constants.EDGE_SEGMENTS_PER_PAGE);
}

fn ensureSegmentReclamationPage(graph: *graph_core.GraphCore, page_idx: u32) ![]types.ReclamationEntry {
    return common.ensureReclamationPageSized(graph, &graph.edge_block_segment_reclamation_pages, page_idx, constants.EDGE_SEGMENTS_PER_PAGE);
}

/// Returns mutable access to one edge-block segment descriptor.
pub fn edgeBlockSegmentAt(graph: *graph_core.GraphCore, segment_idx: u32) *types.EdgeBlockSegment {
    return common.pageEntryAt(types.EdgeBlockSegment, &graph.edge_block_segment_pages, segment_idx, constants.EDGE_SEGMENTS_PER_PAGE);
}

/// Returns read-only access to one edge-block segment descriptor.
pub fn edgeBlockSegmentAtConst(graph: *const graph_core.GraphCore, segment_idx: u32) *const types.EdgeBlockSegment {
    return common.pageEntryAtConst(types.EdgeBlockSegment, &graph.edge_block_segment_pages, segment_idx, constants.EDGE_SEGMENTS_PER_PAGE);
}

fn ensureSegmentPage(graph: *graph_core.GraphCore, page_idx: u32) !void {
    _ = try common.ensurePage(graph, types.EdgeBlockSegment, &graph.edge_block_segment_pages, page_idx, constants.EDGE_SEGMENTS_PER_PAGE);
    _ = try ensureSegmentReclamationPage(graph, page_idx);
}

pub fn ensureSegmentCapacity(graph: *graph_core.GraphCore, required_segment_count: u32) !void {
    if (required_segment_count == 0) return;

    const last_page_idx = common.pageOf(required_segment_count - 1, constants.EDGE_SEGMENTS_PER_PAGE);
    // Frontier invariant: every page covering [0, segment_count) was ensured
    // when those segments were allocated, so only the new tail pages need work.
    var page_idx: u32 = common.pageOf(graph.loadSegmentCount(), constants.EDGE_SEGMENTS_PER_PAGE);
    while (page_idx <= last_page_idx) : (page_idx += 1) {
        try ensureSegmentPage(graph, page_idx);
    }
}

// ── Per-slot-count stacks ─────────────────────────────────────────────

fn segmentSlotStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, slot_count: u16) *std.atomic.Value(u64) {
    std.debug.assert(slot_count > 0 and slot_count <= constants.MAX_SEGMENTS_PER_NODE);
    const slot_count_idx: usize = @intCast(slot_count - 1);
    return switch (kind) {
        .free => &graph.free_segment_slots_head[slot_count_idx],
        .retired => &graph.retired_segment_slots_head[slot_count_idx],
    };
}

fn segmentSlotStack(graph: *graph_core.GraphCore, comptime kind: StackKind, slot_count: u16) index_stack.LockFreeIndexStack {
    return index_stack.LockFreeIndexStack.init(segmentSlotStackHead(graph, kind, slot_count));
}

fn pushSegmentSlotStack(graph: *graph_core.GraphCore, first_segment_idx: u32, slot_count: u16, comptime kind: StackKind) void {
    segmentSlotStack(graph, kind, slot_count).push(segmentReclamationAt(graph, first_segment_idx), first_segment_idx);
}

fn popSegmentSlotStack(graph: *graph_core.GraphCore, comptime kind: StackKind, slot_count: u16) ?u32 {
    const EntryContext = struct {
        graph: *graph_core.GraphCore,

        pub fn entryAt(self: @This(), segment_idx: u32) *types.ReclamationEntry {
            return segmentReclamationAt(self.graph, segment_idx);
        }
    };
    return segmentSlotStack(graph, kind, slot_count).pop(EntryContext{ .graph = graph });
}

fn detachSegmentSlotStack(graph: *graph_core.GraphCore, comptime kind: StackKind, slot_count: u16) u32 {
    return segmentSlotStack(graph, kind, slot_count).detach();
}

// ── Allocation ───────────────────────────────────────────────────────

fn zeroSegmentSlots(graph: *graph_core.GraphCore, first_segment_idx: u32, end_segment_idx: u32) void {
    for (first_segment_idx..end_segment_idx) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        edgeBlockSegmentAt(graph, segment_idx).* = std.mem.zeroes(types.EdgeBlockSegment);
    }
}

fn reserveFreshSegmentSlots(graph: *graph_core.GraphCore, slot_count: u16) !?struct { first_segment_idx: u32, end_segment_idx: u32 } {
    const first_segment_idx = @atomicLoad(u32, &graph.segment_count, .acquire);
    const end_segment_idx = std.math.add(u32, first_segment_idx, slot_count) catch return error.OutOfMemory;
    try ensureSegmentCapacity(graph, end_segment_idx);
    if (@cmpxchgWeak(u32, &graph.segment_count, first_segment_idx, end_segment_idx, .acq_rel, .acquire) != null) return null;
    return .{ .first_segment_idx = first_segment_idx, .end_segment_idx = end_segment_idx };
}

fn allocFreshSegmentSlots(graph: *graph_core.GraphCore, slot_count: u16) !u32 {
    while (true) {
        const reservation = (try reserveFreshSegmentSlots(graph, slot_count)) orelse continue;
        zeroSegmentSlots(graph, reservation.first_segment_idx, reservation.end_segment_idx);
        return reservation.first_segment_idx;
    }
}

/// Allocates zeroed segment descriptor slots, reusing a free slot set when possible.
/// Falls back to a last-resort reclaim pass before failing (see allocBlock).
pub fn allocSegmentSlots(graph: *graph_core.GraphCore, slot_count: u16) !u32 {
    std.debug.assert(slot_count > 0 and slot_count <= constants.MAX_SEGMENTS_PER_NODE);
    if (popSegmentSlotStack(graph, .free, slot_count)) |first_segment_idx| {
        const end_segment_idx = first_segment_idx + slot_count;
        zeroSegmentSlots(graph, first_segment_idx, end_segment_idx);
        return first_segment_idx;
    }

    return allocFreshSegmentSlots(graph, slot_count) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const first_segment_idx = popSegmentSlotStack(graph, .free, slot_count) orelse return err;
            zeroSegmentSlots(graph, first_segment_idx, first_segment_idx + slot_count);
            return first_segment_idx;
        },
    };
}

/// Allocates one segment descriptor.
pub fn allocSegment(graph: *graph_core.GraphCore) !u32 {
    return allocSegmentSlots(graph, 1);
}

// ── Free / retire / reclaim ──────────────────────────────────────────

/// Returns segment descriptor slots to the free stack for that slot count.
pub fn freeSegmentSlots(graph: *graph_core.GraphCore, first_segment_idx: u32, slot_count: u16) void {
    pushSegmentSlotStack(graph, first_segment_idx, slot_count, .free);
}

/// Returns one segment descriptor to the free stack.
pub fn freeSegment(graph: *graph_core.GraphCore, segment_idx: u32) void {
    freeSegmentSlots(graph, segment_idx, 1);
}

/// Moves segment descriptor slots to the retired stack with its retirement epoch.
pub fn retireSegmentSlots(graph: *graph_core.GraphCore, first_segment_idx: u32, slot_count: u16, epoch: u64) void {
    const entry = segmentReclamationAt(graph, first_segment_idx);
    entry.retired_epoch.store(epoch, .release);
    pushSegmentSlotStack(graph, first_segment_idx, slot_count, .retired);
}

/// Retires one segment descriptor.
pub fn retireSegment(graph: *graph_core.GraphCore, segment_idx: u32, epoch: u64) void {
    retireSegmentSlots(graph, segment_idx, 1, epoch);
}

fn requeueOrFreeRetiredSegmentSlots(graph: *graph_core.GraphCore, segment_idx: u32, slot_count: u16, safe_epoch: u64) void {
    const entry = segmentReclamationAt(graph, segment_idx);
    const retired_epoch = entry.retired_epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeSegmentSlots(graph, segment_idx, slot_count);
    } else {
        pushSegmentSlotStack(graph, segment_idx, slot_count, .retired);
    }
}

/// Reclaims segment descriptor slots whose retirement epoch is safe for reuse.
pub fn reclaimRetiredSegments(graph: *graph_core.GraphCore, safe_epoch: u64) void {
    var slot_count: u16 = 1;
    while (slot_count <= constants.MAX_SEGMENTS_PER_NODE) : (slot_count += 1) {
        var segment_idx = detachSegmentSlotStack(graph, .retired, slot_count);
        while (segment_idx != EMPTY_INDEX) {
            const entry = segmentReclamationAt(graph, segment_idx);
            const next = entry.next.load(.acquire);
            requeueOrFreeRetiredSegmentSlots(graph, segment_idx, slot_count, safe_epoch);
            segment_idx = next;
        }
    }
}
