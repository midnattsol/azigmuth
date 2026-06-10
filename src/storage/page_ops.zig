//! Page-based indexed access and allocation for graph storage.

const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency/mod.zig");
const rcu = @import("../concurrency/rcu.zig");
const node_meta = @import("node/meta.zig");
const node_hot = @import("node/hot.zig");
const node_hot_layout = @import("node/hot_layout.zig");
const node_published = @import("node/published.zig");
const node_tiny = @import("node/tiny.zig");

const EMPTY_INDEX: u32 = constants.END_OF_CHAIN;
const StackKind = enum { free, retired };

pub inline fn pageOf(index: u32, comptime entries_per_page: u32) u32 {
    return index / entries_per_page;
}

pub inline fn slotOf(index: u32, comptime entries_per_page: u32) u32 {
    return index % entries_per_page;
}

pub inline fn makeIndex(page_index: u32, slot_index: u32, comptime entries_per_page: u32) u32 {
    return page_index * entries_per_page + slot_index;
}

/// Returns mutable access to one node buffer by flat node id.
pub fn nodeAt(graph: *graph_core.GraphCore, id: types.NodeId) *types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPageMut(types.NodeBuffer, &graph.node_pages_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeMetaAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_meta.NodeMeta {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPageMut(node_meta.NodeMeta, &graph.node_meta_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeMetaPage(graph: *graph_core.GraphCore, page_index: u32) ![]node_meta.NodeMeta {
    return ensurePage(graph, node_meta.NodeMeta, &graph.node_meta_pages, page_index, constants.NODES_PER_PAGE);
}

/// Ensures the node page exists and returns mutable access to one node buffer.
pub fn ensureNodeAt(graph: *graph_core.GraphCore, id: types.NodeId) !*types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodePage(graph, page_index);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

/// Returns read-only access to one node buffer by flat node id.
pub fn nodeAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPage(types.NodeBuffer, &graph.node_pages_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeMetaAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_meta.NodeMeta {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPage(node_meta.NodeMeta, &graph.node_meta_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodePublishedPage(graph: *graph_core.GraphCore, page_index: u32) ![]node_published.NodePublished {
    return ensurePage(graph, node_published.NodePublished, &graph.node_published_pages, page_index, constants.NODES_PER_PAGE);
}

pub fn ensureNodePublishedAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_published.NodePublished {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodePublishedPage(graph, page_index);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodePublishedAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_published.NodePublished {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPageMut(node_published.NodePublished, &graph.node_published_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodePublishedAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_published.NodePublished {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const raw = graph.node_published_pages.load(page_index);
    std.debug.assert(raw != 0);
    const page = loadPage(node_published.NodePublished, &graph.node_published_pages, page_index, constants.NODES_PER_PAGE);
    return &page[slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeHotPage(graph: *graph_core.GraphCore, page_index: u32) ![]node_hot_layout.Slot {
    return ensurePage(graph, node_hot_layout.Slot, &graph.node_hot_pages, page_index, constants.NODES_PER_PAGE);
}

pub fn ensureNodeHotAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_hot.NodeHot {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodeHotPage(graph, page_index);
    return page[slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeHotAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_hot.NodeHot {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPageMut(node_hot_layout.Slot, &graph.node_hot_pages, page_index, constants.NODES_PER_PAGE);
    return page[slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeHotAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_hot.NodeHot {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    const page = loadPage(node_hot_layout.Slot, &graph.node_hot_pages, page_index, constants.NODES_PER_PAGE);
    return page[slotOf(id.index, constants.NODES_PER_PAGE)].nodeConst();
}

fn ensureTinyFwdPage(graph: *graph_core.GraphCore, page_index: u32) ![]node_tiny.TinyFwdSlot {
    _ = try ensureMetaPageSized(graph, &graph.tiny_fwd_meta_pages, page_index, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
    return ensurePage(graph, node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, page_index, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

fn ensureTinyRevPage(graph: *graph_core.GraphCore, page_index: u32) ![]node_tiny.TinyRevSlot {
    _ = try ensureMetaPageSized(graph, &graph.tiny_rev_meta_pages, page_index, node_tiny.TINY_REV_SLOTS_PER_PAGE);
    return ensurePage(graph, node_tiny.TinyRevSlot, &graph.tiny_rev_pages, page_index, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

fn tinyMetaAt(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) *types.BlockMeta {
    return switch (side) {
        .fwd => metaEntryAt(&graph.tiny_fwd_meta_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE),
        .rev => metaEntryAt(&graph.tiny_rev_meta_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE),
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
    pushHeadIndex(tinyStackHead(graph, kind, side), tinyMetaAt(graph, slot_idx, side), slot_idx);
}

fn popTinyStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) ?u32 {
    const head = tinyStackHead(graph, kind, side);

    while (true) {
        const old_head = head.load(.acquire);
        const slot_idx = headIndex(old_head);
        if (slot_idx == EMPTY_INDEX) return null;

        const meta = tinyMetaAt(graph, slot_idx, side);
        const next = meta.next.load(.acquire);
        const new_head = packHead(next, headTag(old_head) +% 1);
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
    var slot_idx = detachHeadIndex(tinyStackHead(graph, .retired, side));
    while (slot_idx != EMPTY_INDEX) {
        const meta = tinyMetaAt(graph, slot_idx, side);
        const next = meta.next.load(.acquire);
        requeueOrFreeRetiredTinySlot(graph, slot_idx, safe_epoch, side);
        slot_idx = next;
    }
}

pub fn tinyFwdAt(graph: *graph_core.GraphCore, slot_idx: u32) *node_tiny.TinyFwdSlot {
    return pageEntryAt(node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

pub fn tinyFwdAtConst(graph: *const graph_core.GraphCore, slot_idx: u32) *const node_tiny.TinyFwdSlot {
    return pageEntryAtConst(node_tiny.TinyFwdSlot, &graph.tiny_fwd_pages, slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

pub fn tinyRevAt(graph: *graph_core.GraphCore, slot_idx: u32) *node_tiny.TinyRevSlot {
    return pageEntryAt(node_tiny.TinyRevSlot, &graph.tiny_rev_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

pub fn tinyRevAtConst(graph: *const graph_core.GraphCore, slot_idx: u32) *const node_tiny.TinyRevSlot {
    return pageEntryAtConst(node_tiny.TinyRevSlot, &graph.tiny_rev_pages, slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

pub fn allocTinyFwdSlot(graph: *graph_core.GraphCore) !u32 {
    if (popTinyStack(graph, .free, .fwd)) |slot_idx| {
        tinyFwdAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyFwdSlot);
        return slot_idx;
    }

    return allocFreshTinyFwdSlot(graph) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const slot_idx = popTinyStack(graph, .free, .fwd) orelse return err;
            tinyFwdAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyFwdSlot);
            return slot_idx;
        },
    };
}

fn allocFreshTinyFwdSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_fwd_count, .acquire);
        const page_index = pageOf(slot_idx, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
        _ = try ensureTinyFwdPage(graph, page_index);
        if (@cmpxchgWeak(u32, &graph.tiny_fwd_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            tinyFwdAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyFwdSlot);
            return slot_idx;
        }
    }
}

pub fn allocTinyRevSlot(graph: *graph_core.GraphCore) !u32 {
    if (popTinyStack(graph, .free, .rev)) |slot_idx| {
        tinyRevAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyRevSlot);
        return slot_idx;
    }

    return allocFreshTinyRevSlot(graph) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const slot_idx = popTinyStack(graph, .free, .rev) orelse return err;
            tinyRevAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyRevSlot);
            return slot_idx;
        },
    };
}

fn allocFreshTinyRevSlot(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const slot_idx = @atomicLoad(u32, &graph.tiny_rev_count, .acquire);
        const page_index = pageOf(slot_idx, node_tiny.TINY_REV_SLOTS_PER_PAGE);
        _ = try ensureTinyRevPage(graph, page_index);
        if (@cmpxchgWeak(u32, &graph.tiny_rev_count, slot_idx, slot_idx + 1, .acq_rel, .acquire) == null) {
            tinyRevAt(graph, slot_idx).* = std.mem.zeroes(node_tiny.TinyRevSlot);
            return slot_idx;
        }
    }
}

/// Returns one published node page as a read-only slice.
pub fn nodePageAtConst(graph: *const graph_core.GraphCore, page_index: u32) []const types.NodeBuffer {
    return loadPage(types.NodeBuffer, &graph.node_pages_pages, page_index, constants.NODES_PER_PAGE);
}

fn ptrFromRaw(comptime T: type, raw: usize, comptime len: usize) []T {
    const page_ptr: [*]T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

fn ptrFromRawConst(comptime T: type, raw: usize, comptime len: usize) []const T {
    const page_ptr: [*]const T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

fn loadPage(comptime T: type, directory: anytype, page_index: u32, comptime entries_per_page: usize) []const T {
    const raw = directory.load(page_index);
    std.debug.assert(raw != 0);
    return ptrFromRawConst(T, raw, entries_per_page);
}

fn loadPageMut(comptime T: type, directory: anytype, page_index: u32, comptime entries_per_page: usize) []T {
    const raw = directory.load(page_index);
    std.debug.assert(raw != 0);
    return ptrFromRaw(T, raw, entries_per_page);
}

fn initMetaPage(page: []types.BlockMeta) void {
    for (page) |*meta| {
        meta.* = .{
            .next = std.atomic.Value(u32).init(EMPTY_INDEX),
            .epoch = std.atomic.Value(u64).init(0),
        };
    }
}

fn ensurePage(
    graph: *graph_core.GraphCore,
    comptime T: type,
    directory: anytype,
    page_index: u32,
    comptime entries_per_page: usize,
) ![]T {
    const slot = try directory.slotPtr(graph.allocator, page_index);
    const existing = slot.load(.acquire);
    if (existing != 0) return ptrFromRaw(T, existing, entries_per_page);

    const new_page = try graph.allocator.alloc(T, entries_per_page);
    errdefer graph.allocator.free(new_page);
    @memset(new_page, std.mem.zeroes(T));
    const new_raw = @intFromPtr(new_page.ptr);

    if (slot.cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(T, published_raw, entries_per_page);
    }

    return new_page;
}

/// Ensures that one node page exists and returns mutable access to it.
pub fn ensureNodePage(graph: *graph_core.GraphCore, page_index: u32) ![]types.NodeBuffer {
    return ensurePage(graph, types.NodeBuffer, &graph.node_pages_pages, page_index, constants.NODES_PER_PAGE);
}

fn ensureMetaPage(graph: *graph_core.GraphCore, directory: anytype, page_index: u32) ![]types.BlockMeta {
    return ensureMetaPageSized(graph, directory, page_index, constants.EDGE_BLOCKS_PER_PAGE);
}

fn ensureMetaPageSized(
    graph: *graph_core.GraphCore,
    directory: anytype,
    page_index: u32,
    comptime entries_per_page: usize,
) ![]types.BlockMeta {
    const slot = try directory.slotPtr(graph.allocator, page_index);
    const existing = slot.load(.acquire);
    if (existing != 0) return ptrFromRaw(types.BlockMeta, existing, entries_per_page);

    const new_page = try graph.allocator.alloc(types.BlockMeta, entries_per_page);
    errdefer graph.allocator.free(new_page);
    initMetaPage(new_page);
    const new_raw = @intFromPtr(new_page.ptr);

    if (slot.cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(types.BlockMeta, published_raw, entries_per_page);
    }

    return new_page;
}

fn metaAt(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) *types.BlockMeta {
    return metaEntryAt(
        if (side == .fwd) &graph.edge_blocks_fwd_meta_pages else &graph.edge_blocks_rev_meta_pages,
        block_index,
        constants.EDGE_BLOCKS_PER_PAGE,
    );
}

fn groupMetaAt(graph: *graph_core.GraphCore, group_index: u32) *types.BlockMeta {
    return metaEntryAt(&graph.edge_block_group_meta_pages, group_index, constants.EDGE_GROUPS_PER_PAGE);
}

fn ensureGroupMetaPage(graph: *graph_core.GraphCore, page_index: u32) ![]types.BlockMeta {
    return ensureMetaPageSized(graph, &graph.edge_block_group_meta_pages, page_index, constants.EDGE_GROUPS_PER_PAGE);
}

fn metaEntryAt(
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *types.BlockMeta {
    const page_index = pageOf(index, entries_per_page);
    const page = loadPageMut(types.BlockMeta, directory, page_index, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

fn packHead(index: u32, tag: u32) u64 {
    return (@as(u64, tag) << 32) | @as(u64, index);
}

fn headIndex(head: u64) u32 {
    return @truncate(head);
}

fn headTag(head: u64) u32 {
    return @truncate(head >> 32);
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

fn groupSpanStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) *std.atomic.Value(u64) {
    std.debug.assert(span_count > 0 and span_count <= constants.MAX_GROUPS_PER_NODE);
    const span_idx: usize = @intCast(span_count - 1);
    return switch (kind) {
        .free => &graph.free_group_spans_head[span_idx],
        .retired => &graph.retired_group_spans_head[span_idx],
    };
}

fn pushHeadIndex(head: *std.atomic.Value(u64), meta: *types.BlockMeta, index: u32) void {
    while (true) {
        const old_head = head.load(.acquire);
        meta.next.store(headIndex(old_head), .release);
        const new_head = packHead(index, headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return;
    }
}

fn detachHeadIndex(head: *std.atomic.Value(u64)) u32 {
    const observed = head.load(.acquire);
    const detached = head.swap(packHead(EMPTY_INDEX, headTag(observed) +% 1), .acq_rel);
    return headIndex(detached);
}

fn pushStack(graph: *graph_core.GraphCore, block_index: u32, comptime kind: StackKind, comptime side: adjacency.AdjSide) void {
    pushHeadIndex(stackHead(graph, kind, side), metaAt(graph, block_index, side), block_index);
}

fn popStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) ?u32 {
    const head = stackHead(graph, kind, side);

    while (true) {
        const old_head = head.load(.acquire);
        const block_index = headIndex(old_head);
        if (block_index == EMPTY_INDEX) return null;

        const meta = metaAt(graph, block_index, side);
        const next = meta.next.load(.acquire);
        const new_head = packHead(next, headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return block_index;
    }
}

fn detachStack(graph: *graph_core.GraphCore, comptime kind: StackKind, comptime side: adjacency.AdjSide) u32 {
    return detachHeadIndex(stackHead(graph, kind, side));
}

fn pushGroupSpanStack(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16, comptime kind: StackKind) void {
    pushHeadIndex(groupSpanStackHead(graph, kind, span_count), groupMetaAt(graph, first_group_idx), first_group_idx);
}

fn popGroupSpanStack(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) ?u32 {
    const head = groupSpanStackHead(graph, kind, span_count);
    while (true) {
        const old_head = head.load(.acquire);
        const group_index = headIndex(old_head);
        if (group_index == EMPTY_INDEX) return null;
        const meta = groupMetaAt(graph, group_index);
        const next = meta.next.load(.acquire);
        const new_head = packHead(next, headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return group_index;
    }
}

fn detachGroupSpanStack(graph: *graph_core.GraphCore, comptime kind: StackKind, span_count: u16) u32 {
    return detachHeadIndex(groupSpanStackHead(graph, kind, span_count));
}

fn pageEntryAt(
    comptime T: type,
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *T {
    const page_index = pageOf(index, entries_per_page);
    const page = loadPageMut(T, directory, page_index, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

fn pageEntryAtConst(
    comptime T: type,
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *const T {
    const page_index = pageOf(index, entries_per_page);
    const page = loadPage(T, directory, page_index, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

/// Returns mutable access to one forward edge block.
pub fn edgeBlockFwdAt(graph: *graph_core.GraphCore, block_index: u32) *types.EdgeBlockFwd {
    return pageEntryAt(types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one forward edge block.
pub fn edgeBlockFwdAtConst(graph: *const graph_core.GraphCore, block_index: u32) *const types.EdgeBlockFwd {
    return pageEntryAtConst(types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one forward edge-id block.
pub fn edgeBlockFwdIdsAt(graph: *graph_core.GraphCore, block_index: u32) *types.EdgeBlockFwdIds {
    return pageEntryAt(types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one forward edge-id block.
pub fn edgeBlockFwdIdsAtConst(graph: *const graph_core.GraphCore, block_index: u32) *const types.EdgeBlockFwdIds {
    return pageEntryAtConst(types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one reverse edge block.
pub fn edgeBlockRevAt(graph: *graph_core.GraphCore, block_index: u32) *types.EdgeBlockRev {
    return pageEntryAt(types.EdgeBlockRev, &graph.edge_blocks_rev_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns read-only access to one reverse edge block.
pub fn edgeBlockRevAtConst(graph: *const graph_core.GraphCore, block_index: u32) *const types.EdgeBlockRev {
    return pageEntryAtConst(types.EdgeBlockRev, &graph.edge_blocks_rev_pages, block_index, constants.EDGE_BLOCKS_PER_PAGE);
}

/// Returns mutable access to one edge block on the requested side.
pub fn edgeBlockAt(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *types.EdgeBlockFwd,
    .rev => *types.EdgeBlockRev,
} {
    return switch (side) {
        .fwd => edgeBlockFwdAt(graph, block_index),
        .rev => edgeBlockRevAt(graph, block_index),
    };
}

/// Returns read-only access to one edge block on the requested side.
pub fn edgeBlockAtConst(graph: *const graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *const types.EdgeBlockFwd,
    .rev => *const types.EdgeBlockRev,
} {
    return switch (side) {
        .fwd => edgeBlockFwdAtConst(graph, block_index),
        .rev => edgeBlockRevAtConst(graph, block_index),
    };
}

/// Returns mutable access to one grouped-run descriptor.
pub fn groupAt(graph: *graph_core.GraphCore, group_index: u32) *types.EdgeBlockGroup {
    return pageEntryAt(types.EdgeBlockGroup, &graph.edge_block_group_pages, group_index, constants.EDGE_GROUPS_PER_PAGE);
}

/// Returns read-only access to one grouped-run descriptor.
pub fn groupAtConst(graph: *const graph_core.GraphCore, group_index: u32) *const types.EdgeBlockGroup {
    return pageEntryAtConst(types.EdgeBlockGroup, &graph.edge_block_group_pages, group_index, constants.EDGE_GROUPS_PER_PAGE);
}

fn ensureGroupPage(graph: *graph_core.GraphCore, page_index: u32) !void {
    _ = try ensurePage(graph, types.EdgeBlockGroup, &graph.edge_block_group_pages, page_index, constants.EDGE_GROUPS_PER_PAGE);
    _ = try ensureGroupMetaPage(graph, page_index);
}

fn ensureGroupCapacity(graph: *graph_core.GraphCore, required_group_count: u32) !void {
    if (required_group_count == 0) return;

    const last_group_index = required_group_count - 1;
    const last_page_index = pageOf(last_group_index, constants.EDGE_GROUPS_PER_PAGE);

    var page_index: u32 = 0;
    while (page_index <= last_page_index) : (page_index += 1) {
        try ensureGroupPage(graph, page_index);
    }
}

fn ensureBlockPage(graph: *graph_core.GraphCore, page_index: u32, comptime side: adjacency.AdjSide) !void {
    switch (side) {
        .fwd => {
            _ = try ensurePage(graph, types.EdgeBlockFwd, &graph.edge_blocks_fwd_pages, page_index, constants.EDGE_BLOCKS_PER_PAGE);
            if (graph.multigraph_enabled) _ = try ensurePage(graph, types.EdgeBlockFwdIds, &graph.edge_blocks_fwd_id_pages, page_index, constants.EDGE_BLOCKS_PER_PAGE);
            _ = try ensureMetaPage(graph, &graph.edge_blocks_fwd_meta_pages, page_index);
        },
        .rev => {
            _ = try ensurePage(graph, types.EdgeBlockRev, &graph.edge_blocks_rev_pages, page_index, constants.EDGE_BLOCKS_PER_PAGE);
            _ = try ensureMetaPage(graph, &graph.edge_blocks_rev_meta_pages, page_index);
        },
    }
}

fn zeroForwardIdsIfNeeded(graph: *graph_core.GraphCore, block_idx: u32) void {
    if (!graph.multigraph_enabled) return;
    edgeBlockFwdIdsAt(graph, block_idx).* = std.mem.zeroes(types.EdgeBlockFwdIds);
}

fn zeroBlock(graph: *graph_core.GraphCore, block_idx: u32, comptime side: adjacency.AdjSide) void {
    edgeBlockAt(graph, block_idx, side).* = std.mem.zeroes(switch (side) {
        .fwd => types.EdgeBlockFwd,
        .rev => types.EdgeBlockRev,
    });
    if (side == .fwd) zeroForwardIdsIfNeeded(graph, block_idx);
}

fn zeroBlockRange(graph: *graph_core.GraphCore, first_block_idx: u32, end_block_idx: u32, comptime side: adjacency.AdjSide) void {
    for (first_block_idx..end_block_idx) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        zeroBlock(graph, block_idx, side);
    }
}

fn reserveFreshBlockSpan(graph: *graph_core.GraphCore, span_count: u32, comptime side: adjacency.AdjSide) !?struct { first_block_idx: u32, end_block_idx: u32 } {
    const first_block_idx = switch (side) {
        .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
        .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
    };
    const end_block_idx = std.math.add(u32, first_block_idx, span_count) catch return error.OutOfMemory;

    try ensureBlockCapacity(graph, end_block_idx, side);
    const published = switch (side) {
        .fwd => @cmpxchgWeak(u32, &graph.block_fwd_count, first_block_idx, end_block_idx, .acq_rel, .acquire),
        .rev => @cmpxchgWeak(u32, &graph.block_rev_count, first_block_idx, end_block_idx, .acq_rel, .acquire),
    };
    if (published != null) return null;

    return .{ .first_block_idx = first_block_idx, .end_block_idx = end_block_idx };
}

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

fn requeueOrFreeRetiredBlock(graph: *graph_core.GraphCore, block_idx: u32, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    const meta = metaAt(graph, block_idx, side);
    const retired_epoch = meta.epoch.load(.acquire);
    if (retired_epoch < safe_epoch) {
        freeBlock(graph, block_idx, side);
    } else {
        pushStack(graph, block_idx, .retired, side);
    }
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

fn allocFreshBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    while (true) {
        const block_index = switch (side) {
            .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
            .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
        };
        const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);

        try ensureBlockPage(graph, page_index, side);
        switch (side) {
            .fwd => if (@cmpxchgWeak(u32, &graph.block_fwd_count, block_index, block_index + 1, .acq_rel, .acquire) == null) return block_index,
            .rev => if (@cmpxchgWeak(u32, &graph.block_rev_count, block_index, block_index + 1, .acq_rel, .acquire) == null) return block_index,
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

/// Ensures backing pages exist for blocks up to `required_block_count` on one side.
pub fn ensureBlockCapacity(graph: *graph_core.GraphCore, required_block_count: u32, comptime side: adjacency.AdjSide) !void {
    if (required_block_count == 0) return;

    const last_block_index = required_block_count - 1;
    const last_page_index = pageOf(last_block_index, constants.EDGE_BLOCKS_PER_PAGE);

    var page_index: u32 = 0;
    while (page_index <= last_page_index) : (page_index += 1) {
        try ensureBlockPage(graph, page_index, side);
    }
}

/// Allocates one zeroed block, reusing the free stack when available.
///
/// Last-resort path: when fresh block space is exhausted (structural index
/// limit or allocator failure), one reclaim pass runs before giving up so
/// that epoch-safe retired blocks are preferred over a hard failure. This is
/// not hidden periodic maintenance — it only triggers when the alternative
/// is returning error.OutOfMemory.
pub fn allocBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    if (popStack(graph, .free, side)) |block_index| {
        zeroBlock(graph, block_index, side);
        return block_index;
    }

    return allocFreshBlock(graph, side) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            const block_index = popStack(graph, .free, side) orelse return err;
            zeroBlock(graph, block_index, side);
            return block_index;
        },
    };
}

/// Returns one block to the per-side free stack.
pub fn freeBlock(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) void {
    pushStack(graph, block_index, .free, side);
}

/// Moves one block to the retired stack with its retirement epoch recorded.
pub fn retireBlock(graph: *graph_core.GraphCore, block_index: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
    const meta = metaAt(graph, block_index, side);
    meta.epoch.store(epoch, .release);
    pushStack(graph, block_index, .retired, side);
}

/// Reclaims retired blocks whose epoch is now safe for reuse.
pub fn reclaimRetired(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var block_index = detachStack(graph, .retired, side);
    while (block_index != EMPTY_INDEX) {
        const meta = metaAt(graph, block_index, side);
        const next = meta.next.load(.acquire);
        requeueOrFreeRetiredBlock(graph, block_index, safe_epoch, side);
        block_index = next;
    }
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

/// Returns one grouped-run span to the free stack for that span size.
pub fn freeGroupSpan(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16) void {
    pushGroupSpanStack(graph, first_group_idx, span_count, .free);
}

/// Returns one grouped-run descriptor to the free stack.
pub fn freeGroup(graph: *graph_core.GraphCore, group_index: u32) void {
    freeGroupSpan(graph, group_index, 1);
}

/// Moves one grouped-run span to the retired stack with its retirement epoch.
pub fn retireGroupSpan(graph: *graph_core.GraphCore, first_group_idx: u32, span_count: u16, epoch: u64) void {
    const meta = groupMetaAt(graph, first_group_idx);
    meta.epoch.store(epoch, .release);
    pushGroupSpanStack(graph, first_group_idx, span_count, .retired);
}

/// Retires one grouped-run descriptor.
pub fn retireGroup(graph: *graph_core.GraphCore, group_index: u32, epoch: u64) void {
    retireGroupSpan(graph, group_index, 1, epoch);
}

/// Reclaims grouped-run spans whose retirement epoch is safe for reuse.
pub fn reclaimRetiredGroups(graph: *graph_core.GraphCore, safe_epoch: u64) void {
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        var group_index = detachGroupSpanStack(graph, .retired, span_count);
        while (group_index != EMPTY_INDEX) {
            const meta = groupMetaAt(graph, group_index);
            const next = meta.next.load(.acquire);
            requeueOrFreeRetiredGroupSpan(graph, group_index, span_count, safe_epoch);
            group_index = next;
        }
    }
}
