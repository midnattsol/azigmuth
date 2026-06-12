//! Grouped-run descriptor pool: group page access, span allocation, and the
//! per-span-length free/retired stacks (published grouped sides own one
//! contiguous span of run descriptors, so the span length must round-trip
//! through the stacks).

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("common.zig");

const EMPTY_INDEX = common.EMPTY_INDEX;
const StackKind = common.StackKind;

fn groupMetaAt(graph: *graph_core.GraphCore, group_idx: u32) *types.BlockMeta {
    return common.metaEntryAt(&graph.edge_block_group_meta_pages, group_idx, constants.EDGE_GROUPS_PER_PAGE);
}

fn ensureGroupMetaPage(graph: *graph_core.GraphCore, page_idx: u32) ![]types.BlockMeta {
    return common.ensureMetaPageSized(graph, &graph.edge_block_group_meta_pages, page_idx, constants.EDGE_GROUPS_PER_PAGE);
}

/// Returns mutable access to one grouped-run descriptor.
pub fn groupAt(graph: *graph_core.GraphCore, group_idx: u32) *types.EdgeBlockGroup {
    return common.pageEntryAt(types.EdgeBlockGroup, &graph.edge_block_group_pages, group_idx, constants.EDGE_GROUPS_PER_PAGE);
}

/// Returns read-only access to one grouped-run descriptor.
pub fn groupAtConst(graph: *const graph_core.GraphCore, group_idx: u32) *const types.EdgeBlockGroup {
    return common.pageEntryAtConst(types.EdgeBlockGroup, &graph.edge_block_group_pages, group_idx, constants.EDGE_GROUPS_PER_PAGE);
}

fn ensureGroupPage(graph: *graph_core.GraphCore, page_idx: u32) !void {
    _ = try common.ensurePage(graph, types.EdgeBlockGroup, &graph.edge_block_group_pages, page_idx, constants.EDGE_GROUPS_PER_PAGE);
    _ = try ensureGroupMetaPage(graph, page_idx);
}

fn ensureGroupCapacity(graph: *graph_core.GraphCore, required_group_count: u32) !void {
    if (required_group_count == 0) return;

    const last_page_idx = common.pageOf(required_group_count - 1, constants.EDGE_GROUPS_PER_PAGE);
    // Frontier invariant: every page covering [0, group_count) was ensured
    // when those groups were allocated, so only the new tail pages need work.
    var page_idx: u32 = common.pageOf(graph.loadGroupCount(), constants.EDGE_GROUPS_PER_PAGE);
    while (page_idx <= last_page_idx) : (page_idx += 1) {
        try ensureGroupPage(graph, page_idx);
    }
}

// ── Per-span-length stacks ───────────────────────────────────────────

fn groupSpanStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) *std.atomic.Value(u64) {
    std.debug.assert(span_count > 0 and span_count <= constants.MAX_GROUPS_PER_NODE);
    const span_idx: usize = @intCast(span_count - 1);
    return switch (kind) {
        .free => &graph.free_group_spans_head[span_idx],
        .retired => &graph.retired_group_spans_head[span_idx],
    };
}

fn pushGroupSpanStack(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16, comptime kind: StackKind) void {
    common.pushHeadIndex(groupSpanStackHead(graph, kind, span_count), groupMetaAt(graph, first_group_idx), first_group_idx);
}

fn popGroupSpanStack(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) ?u32 {
    const head = groupSpanStackHead(graph, kind, span_count);
    while (true) {
        const old_head = head.load(.acquire);
        const group_idx = common.headIndex(old_head);
        if (group_idx == EMPTY_INDEX) return null;
        const meta = groupMetaAt(graph, group_idx);
        const next = meta.next.load(.acquire);
        const new_head = common.packHead(next, common.headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return group_idx;
    }
}

fn detachGroupSpanStack(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) u32 {
    return common.detachHeadIndex(groupSpanStackHead(graph, kind, span_count));
}

// ── Allocation ───────────────────────────────────────────────────────

fn zeroGroupRange(graph: *graph_core.GraphCore, first_group_idx: u32, end_group_idx: u32) void {
    for (first_group_idx..end_group_idx) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        groupAt(graph, group_idx).* = std.mem.zeroes(types.EdgeBlockGroup);
    }
}

fn reserveFreshGroupSpan(graph: *graph_core.GraphCore, span_count: u16) !?struct { first_group_idx: u32, end_group_idx: u32 } {
    const first_group_idx = @atomicLoad(u32, &graph.group_count, .acquire);
    const end_group_idx = std.math.add(u32, first_group_idx, span_count) catch return error.OutOfMemory;
    try ensureGroupCapacity(graph, end_group_idx);
    if (@cmpxchgWeak(u32, &graph.group_count, first_group_idx, end_group_idx, .acq_rel, .acquire) != null) return null;
    return .{ .first_group_idx = first_group_idx, .end_group_idx = end_group_idx };
}

fn allocFreshGroupSpan(graph: *graph_core.GraphCore, span_count: u16) !u32 {
    while (true) {
        const reservation = (try reserveFreshGroupSpan(graph, span_count)) orelse continue;
        zeroGroupRange(graph, reservation.first_group_idx, reservation.end_group_idx);
        return reservation.first_group_idx;
    }
}

/// Allocates one zeroed grouped-run span, reusing a free span when possible.
/// Falls back to a last-resort reclaim pass before failing (see allocBlock).
pub fn allocGroupSpan(graph: *graph_core.GraphCore, span_count: u16) !u32 {
    std.debug.assert(span_count > 0 and span_count <= constants.MAX_GROUPS_PER_NODE);
    if (popGroupSpanStack(graph, .free, span_count)) |first_group_idx| {
        const end_group_idx = first_group_idx + span_count;
        zeroGroupRange(graph, first_group_idx, end_group_idx);
        return first_group_idx;
    }

    return allocFreshGroupSpan(graph, span_count) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const first_group_idx = popGroupSpanStack(graph, .free, span_count) orelse return err;
            zeroGroupRange(graph, first_group_idx, first_group_idx + span_count);
            return first_group_idx;
        },
    };
}

/// Allocates one grouped-run descriptor.
pub fn allocGroup(graph: *graph_core.GraphCore) !u32 {
    return allocGroupSpan(graph, 1);
}

// ── Free / retire / reclaim ──────────────────────────────────────────

/// Returns one grouped-run span to the free stack for that span size.
pub fn freeGroupSpan(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16) void {
    pushGroupSpanStack(graph, first_group_idx, span_count, .free);
}

/// Returns one grouped-run descriptor to the free stack.
pub fn freeGroup(graph: *graph_core.GraphCore, group_idx: u32) void {
    freeGroupSpan(graph, group_idx, 1);
}

/// Moves one grouped-run span to the retired stack with its retirement epoch.
pub fn retireGroupSpan(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16, epoch: u64) void {
    const meta = groupMetaAt(graph, first_group_idx);
    meta.epoch.store(epoch, .release);
    pushGroupSpanStack(graph, first_group_idx, span_count, .retired);
}

/// Retires one grouped-run descriptor.
pub fn retireGroup(graph: *graph_core.GraphCore, group_idx: u32, epoch: u64) void {
    retireGroupSpan(graph, group_idx, 1, epoch);
}

fn requeueOrFreeRetiredGroupSpan(graph: *graph_core.GraphCore, group_idx: u32, span_count: u16, safe_epoch: u64) void {
    const meta = groupMetaAt(graph, group_idx);
    const retired_epoch = meta.epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeGroupSpan(graph, group_idx, span_count);
    } else {
        pushGroupSpanStack(graph, group_idx, span_count, .retired);
    }
}

/// Reclaims grouped-run spans whose retirement epoch is safe for reuse.
pub fn reclaimRetiredGroups(graph: *graph_core.GraphCore, safe_epoch: u64) void {
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        var group_idx = detachGroupSpanStack(graph, .retired, span_count);
        while (group_idx != EMPTY_INDEX) {
            const meta = groupMetaAt(graph, group_idx);
            const next = meta.next.load(.acquire);
            requeueOrFreeRetiredGroupSpan(graph, group_idx, span_count, safe_epoch);
            group_idx = next;
        }
    }
}
