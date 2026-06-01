//! Page-based indexed access and allocation for graph storage.

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const adjacency = @import("adjacency.zig");

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

pub fn nodeAt(graph: *graph_core.GraphCore, id: types.NodeId) *types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    return &graph.node_pages.items[page_index][slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    return &graph.node_pages.items[page_index][slotOf(id.index, constants.NODES_PER_PAGE)];
}

fn ptrFromRaw(comptime T: type, raw: usize, comptime len: usize) []T {
    const page_ptr: [*]T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

fn ptrFromRawConst(comptime T: type, raw: usize, comptime len: usize) []const T {
    const page_ptr: [*]const T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

fn loadPage(comptime T: type, pages: []const std.atomic.Value(usize), page_index: u32, comptime entries_per_page: usize) []const T {
    const raw = pages[@intCast(page_index)].load(.acquire);
    std.debug.assert(raw != 0);
    return ptrFromRawConst(T, raw, entries_per_page);
}

fn loadPageMut(comptime T: type, pages: []const std.atomic.Value(usize), page_index: u32, comptime entries_per_page: usize) []T {
    const raw = pages[@intCast(page_index)].load(.acquire);
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
    pages: []std.atomic.Value(usize),
    legacy_pages: *std.ArrayList([]T),
    page_index: u32,
    comptime entries_per_page: usize,
) ![]T {
    if (page_index >= pages.len) return error.OutOfMemory;

    const existing = pages[@intCast(page_index)].load(.acquire);
    if (existing != 0) return ptrFromRaw(T, existing, entries_per_page);

    const new_page = try graph.allocator.alloc(T, entries_per_page);
    @memset(new_page, std.mem.zeroes(T));
    const new_raw = @intFromPtr(new_page.ptr);

    if (pages[@intCast(page_index)].cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(T, published_raw, entries_per_page);
    }

    // After the page pointer is published in the atomic directory, this helper
    // must not fail: callers and lock-free readers may already observe it. The
    // legacy ArrayList is only for debug/inspection paths; deinit frees pages
    // from the atomic directories, so failing to mirror the page here is safe.
    if (graph.active_writers.load(.monotonic) == 0) {
        legacy_pages.append(graph.allocator, new_page) catch {};
    }
    return new_page;
}

fn ensureMetaPage(graph: *graph_core.GraphCore, pages: []std.atomic.Value(usize), page_index: u32) ![]types.BlockMeta {
    if (page_index >= pages.len) return error.OutOfMemory;

    const existing = pages[@intCast(page_index)].load(.acquire);
    if (existing != 0) return ptrFromRaw(types.BlockMeta, existing, constants.EDGE_BLOCKS_PER_PAGE);

    const new_page = try graph.allocator.alloc(types.BlockMeta, constants.EDGE_BLOCKS_PER_PAGE);
    errdefer graph.allocator.free(new_page);
    initMetaPage(new_page);
    const new_raw = @intFromPtr(new_page.ptr);

    if (pages[@intCast(page_index)].cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(types.BlockMeta, published_raw, constants.EDGE_BLOCKS_PER_PAGE);
    }

    return new_page;
}

fn metaAt(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) *types.BlockMeta {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const pages = if (side == .fwd) graph.edge_blocks_fwd_meta_pages[0..] else graph.edge_blocks_rev_meta_pages[0..];
    const page = loadPageMut(types.BlockMeta, pages, page_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &page[slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
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

fn pushStack(graph: *graph_core.GraphCore, block_index: u32, comptime kind: StackKind, comptime side: adjacency.AdjSide) void {
    const head = stackHead(graph, kind, side);
    const meta = metaAt(graph, block_index, side);

    while (true) {
        const old_head = head.load(.acquire);
        meta.next.store(headIndex(old_head), .release);
        const new_head = packHead(block_index, headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return;
    }
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
    const head = stackHead(graph, kind, side);
    const observed = head.load(.acquire);
    const detached = head.swap(packHead(EMPTY_INDEX, headTag(observed) +% 1), .acq_rel);
    return headIndex(detached);
}

pub fn edgeBlockFwdAt(graph: *graph_core.GraphCore, block_index: u32) *types.EdgeBlockFwd {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const page = loadPageMut(types.EdgeBlockFwd, graph.edge_blocks_fwd_pages[0..], page_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &page[slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockFwdAtConst(graph: *const graph_core.GraphCore, block_index: u32) *const types.EdgeBlockFwd {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const page = loadPage(types.EdgeBlockFwd, graph.edge_blocks_fwd_pages[0..], page_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &page[slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockRevAt(graph: *graph_core.GraphCore, block_index: u32) *types.EdgeBlockRev {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const page = loadPageMut(types.EdgeBlockRev, graph.edge_blocks_rev_pages[0..], page_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &page[slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockRevAtConst(graph: *const graph_core.GraphCore, block_index: u32) *const types.EdgeBlockRev {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const page = loadPage(types.EdgeBlockRev, graph.edge_blocks_rev_pages[0..], page_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &page[slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockAt(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *types.EdgeBlockFwd,
    .rev => *types.EdgeBlockRev,
} {
    if (side == .fwd) return edgeBlockFwdAt(graph, block_index);
    if (side == .rev) return edgeBlockRevAt(graph, block_index);
}

pub fn edgeBlockAtConst(graph: *const graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *const types.EdgeBlockFwd,
    .rev => *const types.EdgeBlockRev,
} {
    if (side == .fwd) return edgeBlockFwdAtConst(graph, block_index);
    if (side == .rev) return edgeBlockRevAtConst(graph, block_index);
}

pub fn groupAt(graph: *graph_core.GraphCore, group_index: u32) *types.EdgeBlockGroup {
    const page_index = pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    const page = loadPageMut(types.EdgeBlockGroup, graph.edge_block_group_pages[0..], page_index, constants.EDGE_GROUPS_PER_PAGE);
    return &page[slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)];
}

pub fn groupAtConst(graph: *const graph_core.GraphCore, group_index: u32) *const types.EdgeBlockGroup {
    const page_index = pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    const page = loadPage(types.EdgeBlockGroup, graph.edge_block_group_pages[0..], page_index, constants.EDGE_GROUPS_PER_PAGE);
    return &page[slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)];
}

fn allocFreshBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    while (true) {
        const block_index = switch (side) {
            .fwd => @atomicLoad(u32, &graph.block_fwd_count, .acquire),
            .rev => @atomicLoad(u32, &graph.block_rev_count, .acquire),
        };
        const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);

        switch (side) {
            .fwd => {
                _ = try ensurePage(graph, types.EdgeBlockFwd, graph.edge_blocks_fwd_pages[0..], &graph.edge_blocks_fwd, page_index, constants.EDGE_BLOCKS_PER_PAGE);
                _ = try ensureMetaPage(graph, graph.edge_blocks_fwd_meta_pages[0..], page_index);
                if (@cmpxchgWeak(u32, &graph.block_fwd_count, block_index, block_index + 1, .acq_rel, .acquire) == null) return block_index;
            },
            .rev => {
                _ = try ensurePage(graph, types.EdgeBlockRev, graph.edge_blocks_rev_pages[0..], &graph.edge_blocks_rev, page_index, constants.EDGE_BLOCKS_PER_PAGE);
                _ = try ensureMetaPage(graph, graph.edge_blocks_rev_meta_pages[0..], page_index);
                if (@cmpxchgWeak(u32, &graph.block_rev_count, block_index, block_index + 1, .acq_rel, .acquire) == null) return block_index;
            },
        }
    }
}

fn removeDebugFree(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) void {
    if (graph.active_writers.load(.monotonic) > 1) return;
    if (!graph.debug_retired_enabled.load(.monotonic)) return;

    const list = switch (side) {
        .fwd => &graph.free_blocks_fwd,
        .rev => &graph.free_blocks_rev,
    };
    for (list.items, 0..) |item, index| {
        if (item == block_index) {
            _ = list.orderedRemove(index);
            return;
        }
    }
}

pub fn allocBlock(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    if (popStack(graph, .free, side)) |block_index| {
        removeDebugFree(graph, block_index, side);
        edgeBlockAt(graph, block_index, side).* = std.mem.zeroes(switch (side) {
            .fwd => types.EdgeBlockFwd,
            .rev => types.EdgeBlockRev,
        });
        return block_index;
    }

    return try allocFreshBlock(graph, side);
}

pub fn freeBlock(graph: *graph_core.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) void {
    pushStack(graph, block_index, .free, side);
    if (graph.active_writers.load(.monotonic) <= 1 and graph.debug_retired_enabled.load(.monotonic)) {
        switch (side) {
            .fwd => graph.free_blocks_fwd.append(graph.allocator, block_index) catch {},
            .rev => graph.free_blocks_rev.append(graph.allocator, block_index) catch {},
        }
    }
}

pub fn retireBlock(graph: *graph_core.GraphCore, block_index: u32, epoch: u64, comptime side: adjacency.AdjSide) void {
    const meta = metaAt(graph, block_index, side);
    meta.epoch.store(epoch, .release);
    pushStack(graph, block_index, .retired, side);
}

pub fn reclaimRetired(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: adjacency.AdjSide) void {
    var block_index = detachStack(graph, .retired, side);
    while (block_index != EMPTY_INDEX) {
        const meta = metaAt(graph, block_index, side);
        const next = meta.next.load(.acquire);
        const retired_epoch = meta.epoch.load(.acquire);
        if (retired_epoch < safe_epoch) {
            freeBlock(graph, block_index, side);
        } else {
            pushStack(graph, block_index, .retired, side);
        }
        block_index = next;
    }
}

pub fn allocGroup(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const group_index = @atomicLoad(u32, &graph.group_count, .acquire);
        const page_index = pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
        const page = try ensurePage(graph, types.EdgeBlockGroup, graph.edge_block_group_pages[0..], &graph.edge_block_groups, page_index, constants.EDGE_GROUPS_PER_PAGE);
        if (@cmpxchgWeak(u32, &graph.group_count, group_index, group_index + 1, .acq_rel, .acquire) == null) {
            page[slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)] = std.mem.zeroes(types.EdgeBlockGroup);
            return group_index;
        }
    }
}

pub fn freeGroup(graph: *graph_core.GraphCore, group_index: u32) void {
    if (graph.active_writers.load(.monotonic) != 0) return;
    graph.free_groups.append(graph.allocator, group_index) catch {};
}
