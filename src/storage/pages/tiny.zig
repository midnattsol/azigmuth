//! Tiny-slot pool: slot pages plus the per-side lock-free free/retired
//! stacks (same retire/reclaim discipline as edge blocks).

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_tiny = @import("../node/tiny.zig");
const common = @import("common.zig");

const EMPTY_INDEX = common.EMPTY_INDEX;
const StackKind = common.StackKind;

fn ensureTinyFwdPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyFwdSlot {
    _ = try common.ensureMetaPageSized(graph, &graph.tiny_fwd_meta_pages, page_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, page_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

fn ensureTinyRevPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyRevSlot {
    _ = try common.ensureMetaPageSized(graph, &graph.tiny_rev_meta_pages, page_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyRevSlot, &graph.tiny_rev_pages, page_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

fn tinyMetaAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *types.BlockMeta {
    return switch (side) {
        .fwd => common.metaEntryAt(&graph.tiny_fwd_meta_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE),
        .rev => common.metaEntryAt(&graph.tiny_rev_meta_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE),
    };
}

fn tinyStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => switch (side) {
            .fwd => &graph.free_tiny_fwd_head,
            .rev => &graph.free_tiny_rev_head,
        },
        .retired => switch (side) {
            .fwd => &graph.retired_tiny_fwd_head,
            .rev => &graph.retired_tiny_rev_head,
        },
    };
}

fn pushTinyStack(graph: *graph_core.GraphCore, slot_idx: u32, comptime kind: StackKind, comptime side: adjacency.AdjSide) void {
    common.pushHeadIndex(tinyStackHead(graph, kind, side), tinyMetaAt(graph, slot_idx, side), slot_idx);
}

fn popTinyStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) ?u32 {
    const head = tinyStackHead(graph, kind, side);

    while (true) {
        const old_head = head.load(.acquire);
        const slot_idx = common.headIndex(old_head);
        if (slot_idx == EMPTY_INDEX) return null;

        const meta = tinyMetaAt(graph, slot_idx, side);
        const next = meta.next.load(.acquire);
        const new_head = common.packHead(next, common.headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return slot_idx;
    }
}

/// Returns one tiny slot to the per-side free stack.
pub fn freeTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) void {
    pushTinyStack(graph, slot_idx, .free, side);
}

/// Moves one tiny slot to the retired stack with its retirement epoch recorded.
pub fn retireTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
    const meta = tinyMetaAt(graph, slot_idx, side);
    meta.epoch.store(epoch, .release);
    pushTinyStack(graph, slot_idx, .retired, side);
}

fn requeueOrFreeRetiredTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    const meta = tinyMetaAt(graph, slot_idx, side);
    const retired_epoch = meta.epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeTinySlot(graph, slot_idx, side);
    } else {
        pushTinyStack(graph, slot_idx, .retired, side);
    }
}

/// Reclaims retired tiny slots whose epoch is now safe for reuse.
pub fn reclaimRetiredTinySlots(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var slot_idx = common.detachHeadIndex(tinyStackHead(graph, .retired, side));
    while (slot_idx != EMPTY_INDEX) {
        const meta = tinyMetaAt(graph, slot_idx, side);
        const next = meta.next.load(.acquire);
        requeueOrFreeRetiredTinySlot(graph, slot_idx, safe_epoch, side);
        slot_idx = next;
    }
}

pub fn tinyFwdAt(graph: *graph_core.GraphCore, slot_idx: u32) *node_tiny.TinyFwdSlot {
    return common.pageEntryAt(node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

pub fn tinyFwdAtConst(graph: *const graph_core.GraphCore, slot_idx: u32) *const node_tiny.TinyFwdSlot {
    return common.pageEntryAtConst(node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

pub fn tinyRevAt(graph: *graph_core.GraphCore, slot_idx: u32) *node_tiny.TinyRevSlot {
    return common.pageEntryAt(node_tiny.TinyRevSlot, &graph.tiny_rev_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

pub fn tinyRevAtConst(graph: *const graph_core.GraphCore, slot_idx: u32) *const node_tiny.TinyRevSlot {
    return common.pageEntryAtConst(node_tiny.TinyRevSlot, &graph.tiny_rev_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

pub fn allocTinyFwdSlot(graph: *graph_core.GraphCore) !u32 {
    const slot_idx = try allocTinyFwdSlotRaw(graph);
    tinyFwdAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyFwdSlot);
    return slot_idx;
}

/// Like allocTinyFwdSlot but skips zero-initialization. Safe when the caller
/// fully overwrites the slot (clone) or only entries [0, count) are ever
/// read by the published descriptor.
pub fn allocTinyFwdSlotRaw(graph: *graph_core.GraphCore) !u32 {
    if (popTinyStack(graph, .free, .fwd)) |slot_idx| return slot_idx;

    return allocFreshTinyFwdSlot(graph) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            return popTinyStack(graph, .free, .fwd) orelse err;
        },
    };
}

fn allocFreshTinyFwdSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_fwd_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
        _ = try ensureTinyFwdPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_fwd_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            return slot_idx;
        }
    }
}

pub fn allocTinyRevSlot(graph: *graph_core.GraphCore) !u32 {
    const slot_idx = try allocTinyRevSlotRaw(graph);
    tinyRevAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyRevSlot);
    return slot_idx;
}

/// See allocTinyFwdSlotRaw.
pub fn allocTinyRevSlotRaw(graph: *graph_core.GraphCore) !u32 {
    if (popTinyStack(graph, .free, .rev)) |slot_idx| return slot_idx;

    return allocFreshTinyRevSlot(graph) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            return popTinyStack(graph, .free, .rev) orelse err;
        },
    };
}

fn allocFreshTinyRevSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_rev_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
        _ = try ensureTinyRevPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_rev_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            return slot_idx;
        }
    }
}
