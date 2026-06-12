const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_validity = @import("../../core/node_validity.zig");
pub fn blockStackHeadIndex(graph: *const graph_core.GraphCore, comptime kind: common.StackKindFast, comptime side: common.Side) u32 {
    const head = switch (kind) {
        .free => switch (side) {
            .fwd => graph.free_blocks_fwd_head.load(.acquire),
            .rev => graph.free_blocks_rev_head.load(.acquire),
        },
        .retired => switch (side) {
            .fwd => graph.retired_blocks_fwd_head.load(.acquire),
            .rev => graph.retired_blocks_rev_head.load(.acquire),
        },
    };
    return @truncate(head);
}

pub fn blockMetaNextFast(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) !u32 {
    if (!common.blockExists(graph, block_idx, side)) return error.CorruptGraph;
    const page_idx = page_ops.pageOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE);
    const raw = switch (side) {
        .fwd => graph.edge_blocks_fwd_meta_pages.load(page_idx),
        .rev => graph.edge_blocks_rev_meta_pages.load(page_idx),
    };
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_BLOCKS_PER_PAGE];
    return page[page_ops.slotOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE)].next.load(.acquire);
}

pub fn populateStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
    comptime side: common.Side,
) !void {
    const limit = common.allocatedBlockCount(graph, side);
    var current = blockStackHeadIndex(graph, kind, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) {
        if (visited >= limit) return error.CorruptGraph;
        visited += 1;
        if (!common.bitmapSet(bitmap, current)) return error.CorruptGraph;
        current = try blockMetaNextFast(graph, current, side);
    }
}

pub fn groupSpanStackHeadIndexFast(graph: *const graph_core.GraphCore, comptime kind: common.StackKindFast, span_count: u16) u32 {
    const span_idx: usize = @intCast(span_count - 1);
    const head = switch (kind) {
        .free => graph.free_group_spans_head[span_idx].load(.acquire),
        .retired => graph.retired_group_spans_head[span_idx].load(.acquire),
    };
    return @truncate(head);
}

pub fn groupMetaNextFast(graph: *const graph_core.GraphCore, group_idx: u32) !u32 {
    if (group_idx >= graph.loadGroupCount()) return error.CorruptGraph;
    const page_idx = page_ops.pageOf(group_idx, constants.EDGE_GROUPS_PER_PAGE);
    const raw = graph.edge_block_group_meta_pages.load(page_idx);
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_GROUPS_PER_PAGE];
    return page[page_ops.slotOf(group_idx, constants.EDGE_GROUPS_PER_PAGE)].next.load(.acquire);
}

pub fn populateGroupStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
) !void {
    const limit = graph.loadGroupCount();
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        var current = groupSpanStackHeadIndexFast(graph, kind, span_count);
        var visited: u32 = 0;
        while (current != constants.END_OF_CHAIN) {
            if (visited >= limit) return error.CorruptGraph;
            visited += 1;
            for (current..current + span_count) |group_idx_usize| {
                const group_idx: u32 = @intCast(group_idx_usize);
                if (!common.bitmapSet(bitmap, group_idx)) return error.CorruptGraph;
            }
            current = try groupMetaNextFast(graph, current);
        }
    }
}
