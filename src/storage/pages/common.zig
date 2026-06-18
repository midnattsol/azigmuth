//! Shared page machinery for the storage pools: index↔page arithmetic and
//! lazy page publication (CAS into the radix directories).

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const index_stack = @import("index_stack.zig");

const EMPTY_INDEX: u32 = index_stack.EMPTY_INDEX;

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

fn initReclamationPage(page: []types.ReclamationEntry) void {
    for (page) |*entry| {
        entry.* = .{
            .next = std.atomic.Value(u32).init(EMPTY_INDEX),
            .retired_epoch = std.atomic.Value(u64).init(0),
        };
    }
}

pub fn ensureReclamationPage(graph: *graph_core.GraphCore, directory: anytype, page_idx: u32) ![]types.ReclamationEntry {
    return ensureReclamationPageSized(graph, directory, page_idx, constants.EDGE_BLOCKS_PER_PAGE);
}

pub fn ensureReclamationPageSized(
    graph: *graph_core.GraphCore,
    directory: anytype,
    page_idx: u32,
    comptime entries_per_page: usize,
) ![]types.ReclamationEntry {
    const slot = try directory.slotPtr(graph.allocator, page_idx);
    const existing = slot.load(.acquire);
    if (existing != 0) return ptrFromRaw(types.ReclamationEntry, existing, entries_per_page);

    const new_page = try graph.allocator.alloc(types.ReclamationEntry, entries_per_page);
    errdefer graph.allocator.free(new_page);
    initReclamationPage(new_page);
    const new_raw = @intFromPtr(new_page.ptr);

    if (slot.cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(types.ReclamationEntry, published_raw, entries_per_page);
    }

    return new_page;
}

pub fn reclamationEntryAt(
    directory: anytype,
    index: u32,
    comptime entries_per_page: u32,
) *types.ReclamationEntry {
    const page_idx = pageOf(index, entries_per_page);
    const page = loadPageMut(types.ReclamationEntry, directory, page_idx, entries_per_page);
    return &page[slotOf(index, entries_per_page)];
}
