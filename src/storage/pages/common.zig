//! Shared page machinery for the storage pools: index↔page arithmetic,
//! lazy page publication (CAS into the radix directories), and the
//! tagged-head helpers every lock-free free/retired stack family builds on.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");

pub const EMPTY_INDEX: u32 = constants.END_OF_CHAIN;
pub const StackKind = enum { free, retired };

pub inline fn pageOf(index: u32, comptime entries_per_page: u32) u32 {
    return index / entries_per_page;
}

pub inline fn slotOf(index: u32, comptime entries_per_page: u32) u32 {
    return index % entries_per_page;
}

pub inline fn makeIndex(page_idx: u32, slot_idx: u32, comptime entries_per_page: u32) u32 {
    return page_idx * entries_per_page + slot_idx;
}

// ── Raw page access ──────────────────────────────────────────────────

pub fn ptrFromRaw(comptime T: type, raw: usize, comptime len: usize) []T {
    const page_ptr: [*]T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

pub fn ptrFromRawConst(comptime T: type, raw: usize, comptime len: usize) []const T {
    const page_ptr: [*]const T = @ptrFromInt(raw);
    return page_ptr[0..len];
}

pub fn loadPage(comptime T: type, directory: anytype, page_idx: u32, comptime entries_per_page: usize) []const T {
    const raw = directory.load(page_idx);
    std.debug.assert(raw != 0);
    return ptrFromRawConst(T, raw, entries_per_page);
}

pub fn loadPageMut(comptime T: type, directory: anytype, page_idx: u32, comptime entries_per_page: usize) []T {
    const raw = directory.load(page_idx);
    std.debug.assert(raw != 0);
    return ptrFromRaw(T, raw, entries_per_page);
}

pub fn pageEntryAt(
    comptime T: type,
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *T {
    const page_idx = pageOf(index, entries_per_page);
    const page = loadPageMut(T, directory, page_idx, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

pub fn pageEntryAtConst(
    comptime T: type,
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *const T {
    const page_idx = pageOf(index, entries_per_page);
    const page = loadPage(T, directory, page_idx, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

// ── Lazy page publication ────────────────────────────────────────────

pub fn ensurePage(
    graph: *graph_core.GraphCore,
    comptime T: type,
    directory: anytype,
    page_idx: u32,
    comptime entries_per_page: usize,
) ![]T {
    const slot = try directory.slotPtr(graph.allocator, page_idx);
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

fn initMetaPage(page: []types.BlockMeta) void {
    for (page) |*meta| {
        meta.* = .{
            .next = std.atomic.Value(u32).init(EMPTY_INDEX),
            .epoch = std.atomic.Value(u64).init(0),
        };
    }
}

pub fn ensureMetaPage(graph: *graph_core.GraphCore, directory: anytype, page_idx: u32) ![]types.BlockMeta {
    return ensureMetaPageSized(graph, directory, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

pub fn ensureMetaPageSized(
    graph: *graph_core.GraphCore,
    directory: anytype,
    page_idx: u32,
    comptime entries_per_page: usize,
) ![]types.BlockMeta {
    const slot = try directory.slotPtr(graph.allocator, page_idx);
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

pub fn metaEntryAt(
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *types.BlockMeta {
    const page_idx = pageOf(index, entries_per_page);
    const page = loadPageMut(types.BlockMeta, directory, page_idx, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}

// ── Tagged stack heads (low 32 bits index, high 32 bits ABA tag) ─────

pub fn packHead(index: u32, tag: u32) u64 {
    return (@as(u64, tag) << 32) | @as(u64, index);
}

pub fn headIndex(head: u64) u32 {
    return @truncate(head);
}

pub fn headTag(head: u64) u32 {
    return @truncate(head >> 32);
}

pub fn pushHeadIndex(head: *std.atomic.Value(u64), meta: *types.BlockMeta, index: u32) void {
    while (true) {
        const old_head = head.load(.acquire);
        meta.next.store(headIndex(old_head), .release);
        const new_head = packHead(index, headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return;
    }
}

pub fn detachHeadIndex(head: *std.atomic.Value(u64)) u32 {
    const observed = head.load(.acquire);
    const detached = head.swap(packHead(EMPTY_INDEX, headTag(observed) +% 1), .acq_rel);
    return headIndex(detached);
}
