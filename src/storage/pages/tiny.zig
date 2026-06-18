//! Tiny-slot pool: slot pages plus the per-side lock-free free/retired
//! stacks (same retire/reclaim discipline as edge blocks).

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_tiny = @import("../node/tiny.zig");
const common = @import("common.zig");
const index_stack = @import("index_stack.zig");

const EMPTY_INDEX = index_stack.EMPTY_INDEX;
const StackKind = index_stack.StackKind;

fn ensureTinyFwdPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyFwdSlot {
    _ = try common.ensureReclamationPageSized(graph, &graph.tiny_fwd_slot_reclamation_pages, page_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyFwdSlot, &graph.tiny_fwd_slot_pages, page_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

fn ensureTinyRevPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyRevSlot {
    _ = try common.ensureReclamationPageSized(graph, &graph.tiny_rev_slot_reclamation_pages, page_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyRevSlot, &graph.tiny_rev_slot_pages, page_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

fn tinyReclamationAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *types.ReclamationEntry {
    return switch (side) {
        .fwd => common.reclamationEntryAt(&graph.tiny_fwd_slot_reclamation_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE),
        .rev => common.reclamationEntryAt(&graph.tiny_rev_slot_reclamation_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE),
    };
}

fn tinyStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => switch (side) {
            .fwd => &graph.free_tiny_fwd_slot_head,
            .rev => &graph.free_tiny_rev_slot_head,
        },
        .retired => switch (side) {
            .fwd => &graph.retired_tiny_fwd_slot_head,
            .rev => &graph.retired_tiny_rev_slot_head,
        },
    };
}

fn tinyStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) index_stack.LockFreeIndexStack {
    return index_stack.LockFreeIndexStack.init(tinyStackHead(graph, kind, side));
}

fn pushTinyStack(graph: *graph_core.GraphCore, slot_idx: u32, comptime kind: StackKind, comptime side: adjacency.AdjSide) void {
    tinyStack(graph, kind, side).push(tinyReclamationAt(graph, slot_idx, side), slot_idx);
}

fn popTinyStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) ?u32 {
    const EntryContext = struct {
        graph: *graph_core.GraphCore,

        pub fn entryAt(self: @This(), slot_idx: u32) *types.ReclamationEntry {
            return tinyReclamationAt(self.graph, slot_idx, side);
        }
    };
    return tinyStack(graph, kind, side).pop(EntryContext{ .graph = graph });
}

/// Returns one tiny slot to the per-side free stack.
pub fn freeTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) void {
    pushTinyStack(graph, slot_idx, .free, side);
}

/// Moves one tiny slot to the retired stack with its retirement epoch recorded.
pub fn retireTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
    const entry = tinyReclamationAt(graph, slot_idx, side);
    entry.retired_epoch.store(epoch, .release);
    pushTinyStack(graph, slot_idx, .retired, side);
}

fn requeueOrFreeRetiredTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    const entry = tinyReclamationAt(graph, slot_idx, side);
    const retired_epoch = entry.retired_epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeTinySlot(graph, slot_idx, side);
    } else {
        pushTinyStack(graph, slot_idx, .retired, side);
    }
}

/// Reclaims retired tiny slots whose epoch is now safe for reuse.
pub fn reclaimRetiredTinySlots(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var slot_idx = tinyStack(graph, .retired, side).detach();
    while (slot_idx != EMPTY_INDEX) {
        const entry = tinyReclamationAt(graph, slot_idx, side);
        const next = entry.next.load(.acquire);
        requeueOrFreeRetiredTinySlot(graph, slot_idx, safe_epoch, side);
        slot_idx = next;
    }
}

pub fn tinySlotAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *switch (side) {
    .fwd => node_tiny.TinyFwdSlot,
    .rev => node_tiny.TinyRevSlot,
} {
    return switch (side) {
        .fwd => common.pageEntryAt(node_tiny.TinyFwdSlot, &graph.tiny_fwd_slot_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE),
        .rev => common.pageEntryAt(node_tiny.TinyRevSlot, &graph.tiny_rev_slot_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE),
    };
}

pub fn tinySlotAtConst(graph: *const graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *const switch (side) {
    .fwd => node_tiny.TinyFwdSlot,
    .rev => node_tiny.TinyRevSlot,
} {
    return switch (side) {
        .fwd => common.pageEntryAtConst(node_tiny.TinyFwdSlot, &graph.tiny_fwd_slot_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE),
        .rev => common.pageEntryAtConst(node_tiny.TinyRevSlot, &graph.tiny_rev_slot_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE),
    };
}

pub fn allocTinySlot(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    const slot_idx = try allocTinySlotRaw(graph, side);
    tinySlotAt(graph, slot_idx, side).* = switch (side) {
        .fwd => std.mem.zeroes(node_tiny.TinyFwdSlot),
        .rev => std.mem.zeroes(node_tiny.TinyRevSlot),
    };
    return slot_idx;
}

/// Like allocTinySlot but skips zero-initialization. Safe when the caller
/// fully overwrites the slot (clone) or only entries [0, count) are ever
/// read by the published descriptor.
pub fn allocTinySlotRaw(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    if (popTinyStack(graph, .free, side)) |slot_idx| return slot_idx;

    return switch (side) {
        .fwd => allocFreshTinyFwdSlot(graph),
        .rev => allocFreshTinyRevSlot(graph),
    } catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            return popTinyStack(graph, .free, side) orelse err;
        },
    };
}

fn allocFreshTinyFwdSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_fwd_slot_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
        _ = try ensureTinyFwdPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_fwd_slot_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            return slot_idx;
        }
    }
}

/// See allocTinySlotRaw.
fn allocFreshTinyRevSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_rev_slot_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
        _ = try ensureTinyRevPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_rev_slot_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            return slot_idx;
        }
    }
}

/// Ensures tiny-block pages exist for `required_slot_count` slots on the
/// given side, following the same frontier-invariant strategy as
/// `ensureBlockCapacity`.
pub fn ensureTinyCapacity(graph: *graph_core.GraphCore, required_slot_count: u32, comptime side: adjacency.AdjSide) !void {
    if (required_slot_count == 0) return;

    const per_page = switch (side) {
        .fwd => node_tiny.TINY_FWD_SLOTS_PER_PAGE,
        .rev => node_tiny.TINY_REV_SLOTS_PER_PAGE,
    };
    const last_page_idx = common.pageOf(required_slot_count - 1, per_page);
    const frontier = switch (side) {
        .fwd => graph.loadTinyFwdCount(),
        .rev => graph.loadTinyRevCount(),
    };
    var page_idx: u32 = common.pageOf(frontier, per_page);
    while (page_idx <= last_page_idx) : (page_idx += 1) {
        switch (side) {
            .fwd => _ = try ensureTinyFwdPage(graph, page_idx),
            .rev => _ = try ensureTinyRevPage(graph, page_idx),
        }
    }
}
