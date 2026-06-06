const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");

const Word = std.atomic.Value(u64);
const WORD_BITS: u32 = 64;
pub const WORDS_PER_PAGE: u32 = constants.NODES_PER_PAGE / WORD_BITS;

comptime {
    std.debug.assert(constants.NODES_PER_PAGE % WORD_BITS == 0);
}

fn pageForNode(node_index: u32) u32 {
    return node_index / constants.NODES_PER_PAGE;
}

fn slotWithinPage(node_index: u32) u32 {
    return node_index % constants.NODES_PER_PAGE;
}

fn bitLocation(node_index: u32) struct { page_index: u32, word_idx: usize, mask: u64 } {
    const slot_idx = slotWithinPage(node_index);
    return .{
        .page_index = pageForNode(node_index),
        .word_idx = @intCast(slot_idx / WORD_BITS),
        .mask = @as(u64, 1) << @as(u6, @intCast(slot_idx % WORD_BITS)),
    };
}

fn ptrFromRaw(raw: usize) []Word {
    const page_ptr: [*]Word = @ptrFromInt(raw);
    return page_ptr[0..WORDS_PER_PAGE];
}

fn ptrFromRawConst(raw: usize) []const Word {
    const page_ptr: [*]const Word = @ptrFromInt(raw);
    return page_ptr[0..WORDS_PER_PAGE];
}

fn initPage(page: []Word) void {
    for (page) |*word| word.* = Word.init(0);
}

fn loadPage(pages: []const std.atomic.Value(usize), page_index: u32) ?[]const Word {
    if (page_index >= pages.len) return null;
    const raw = pages[@intCast(page_index)].load(.acquire);
    if (raw == 0) return null;
    return ptrFromRawConst(raw);
}

fn ensurePage(
    graph: *graph_core.GraphCore,
    pages: []std.atomic.Value(usize),
    page_index: u32,
) ![]Word {
    if (page_index >= pages.len) return error.OutOfMemory;

    const existing = pages[@intCast(page_index)].load(.acquire);
    if (existing != 0) return ptrFromRaw(existing);

    const new_page = try graph.allocator.alloc(Word, WORDS_PER_PAGE);
    errdefer graph.allocator.free(new_page);
    initPage(new_page);

    const new_raw = @intFromPtr(new_page.ptr);
    if (pages[@intCast(page_index)].cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
        graph.allocator.free(new_page);
        return ptrFromRaw(published_raw);
    }

    return new_page;
}

fn updateWord(word: *Word, mask: u64, set_bit: bool) bool {
    var expected = word.load(.acquire);
    while (true) {
        const was_set = (expected & mask) != 0;
        if (set_bit and was_set) return true;
        if (!set_bit and !was_set) return false;

        const desired = if (set_bit) expected | mask else expected & ~mask;
        const actual = word.cmpxchgWeak(expected, desired, .acq_rel, .acquire) orelse return was_set;
        expected = actual;
    }
}

pub fn ensurePageForNode(
    graph: *graph_core.GraphCore,
    pages: []std.atomic.Value(usize),
    node_index: u32,
) !void {
    const location = bitLocation(node_index);
    _ = try ensurePage(graph, pages, location.page_index);
}

pub fn isSet(pages: []const std.atomic.Value(usize), node_index: u32) bool {
    const location = bitLocation(node_index);
    const page = loadPage(pages, location.page_index) orelse return false;
    return (page[location.word_idx].load(.acquire) & location.mask) != 0;
}

pub fn setBit(
    graph: *graph_core.GraphCore,
    pages: []std.atomic.Value(usize),
    node_index: u32,
) !void {
    const location = bitLocation(node_index);
    const page = try ensurePage(graph, pages, location.page_index);
    _ = updateWord(&page[location.word_idx], location.mask, true);
}

pub fn clearBit(
    graph: *graph_core.GraphCore,
    pages: []std.atomic.Value(usize),
    node_index: u32,
) !void {
    const location = bitLocation(node_index);
    const page = try ensurePage(graph, pages, location.page_index);
    _ = updateWord(&page[location.word_idx], location.mask, false);
}

pub fn testAndSetBit(
    graph: *graph_core.GraphCore,
    pages: []std.atomic.Value(usize),
    node_index: u32,
) !bool {
    const location = bitLocation(node_index);
    const page = try ensurePage(graph, pages, location.page_index);
    return updateWord(&page[location.word_idx], location.mask, true);
}

pub fn testAndClearBit(pages: []std.atomic.Value(usize), node_index: u32) bool {
    const location = bitLocation(node_index);
    const page = loadPage(pages, location.page_index) orelse return false;
    return updateWord(@constCast(&page[location.word_idx]), location.mask, false);
}
