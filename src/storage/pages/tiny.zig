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

fn ensureTinyFwdPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyFwdBlock {
    _ = try common.ensureMetaPageSized(graph, &graph.tiny_block_fwd_meta_pages, page_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyFwdBlock, &graph.tiny_block_fwd_pages, page_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE);
}

fn ensureTinyRevPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_tiny.TinyRevBlock {
    _ = try common.ensureMetaPageSized(graph, &graph.tiny_block_rev_meta_pages, page_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE);
    return common.ensurePage(graph, node_tiny.TinyRevBlock, &graph.tiny_block_rev_pages, page_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE);
}

fn tinyMetaAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *types.BlockMeta {
    return switch (side) {
        .fwd => common.metaEntryAt(&graph.tiny_block_fwd_meta_pages, slot_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE),
        .rev => common.metaEntryAt(&graph.tiny_block_rev_meta_pages, slot_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE),
    };
}

fn tinyStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => switch (side) {
            .fwd => &graph.free_tiny_block_fwd_head,
            .rev => &graph.free_tiny_block_rev_head,
        },
        .retired => switch (side) {
            .fwd => &graph.retired_tiny_block_fwd_head,
            .rev => &graph.retired_tiny_block_rev_head,
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
pub fn retireTinyBlock(graph: *graph_core.GraphCore, slot_idx: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
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
pub fn reclaimRetiredTinyBlocks(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var slot_idx = common.detachHeadIndex(tinyStackHead(graph, .retired, side));
    while (slot_idx != EMPTY_INDEX) {
        const meta = tinyMetaAt(graph, slot_idx, side);
        const next = meta.next.load(.acquire);
        requeueOrFreeRetiredTinySlot(graph, slot_idx, safe_epoch, side);
        slot_idx = next;
    }
}

pub fn tinyBlockAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *switch (side) {
    .fwd => node_tiny.TinyFwdBlock,
    .rev => node_tiny.TinyRevBlock,
} {
    return switch (side) {
        .fwd => common.pageEntryAt(node_tiny.TinyFwdBlock, &graph.tiny_block_fwd_pages, slot_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE),
        .rev => common.pageEntryAt(node_tiny.TinyRevBlock, &graph.tiny_block_rev_pages, slot_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE),
    };
}

pub fn tinyBlockAtConst(graph: *const graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *const switch (side) {
    .fwd => node_tiny.TinyFwdBlock,
    .rev => node_tiny.TinyRevBlock,
} {
    return switch (side) {
        .fwd => common.pageEntryAtConst(node_tiny.TinyFwdBlock, &graph.tiny_block_fwd_pages, slot_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE),
        .rev => common.pageEntryAtConst(node_tiny.TinyRevBlock, &graph.tiny_block_rev_pages, slot_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE),
    };
}

pub fn allocTinyBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    const slot_idx = try allocTinyBlockRaw(graph, side);
    tinyBlockAt(graph, slot_idx, side).* = switch (side) {
        .fwd => std.mem.zeroes(node_tiny.TinyFwdBlock),
        .rev => std.mem.zeroes(node_tiny.TinyRevBlock),
    };
    return slot_idx;
}

/// Like allocTinyBlock but skips zero-initialization. Safe when the caller
/// fully overwrites the slot (clone) or only entries [0, count) are ever
/// read by the published descriptor.
pub fn allocTinyBlockRaw(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    if (popTinyStack(graph, .free, side)) |slot_idx| return slot_idx;

    return switch (side) {
        .fwd => allocFreshTinyFwdBlock(graph),
        .rev => allocFreshTinyRevBlock(graph),
    } catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            return popTinyStack(graph, .free, side) orelse err;
        },
    };
}

fn allocFreshTinyFwdBlock(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_block_fwd_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_BLOCKS_FWD_PER_PAGE);
        _ = try ensureTinyFwdPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_block_fwd_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            return slot_idx;
        }
    }
}

/// See allocTinyBlockRaw.
fn allocFreshTinyRevBlock(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_block_rev_count, .acquire);
        const page_idx = common.pageOf(slot_idx, node_tiny.TINY_BLOCKS_REV_PER_PAGE);
        _ = try ensureTinyRevPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.tiny_block_rev_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
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
        .fwd => node_tiny.TINY_BLOCKS_FWD_PER_PAGE,
        .rev => node_tiny.TINY_BLOCKS_REV_PER_PAGE,
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
