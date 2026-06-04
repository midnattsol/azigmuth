const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
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

pub fn blockMetaNextFast(graph: *const graph_core.GraphCore, block_index: u32, comptime side: common.Side) !u32 {
    if (!common.blockExists(graph, block_index, side)) return error.CorruptGraph;
    const page_index = page_ops.pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const raw = switch (side) {
        .fwd => graph.edge_blocks_fwd_meta_pages[@intCast(page_index)].load(.acquire),
        .rev => graph.edge_blocks_rev_meta_pages[@intCast(page_index)].load(.acquire),
    };
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_BLOCKS_PER_PAGE];
    return page[page_ops.slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)].next.load(.acquire);
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

pub fn groupStackHeadIndexFast(graph: *const graph_core.GraphCore, comptime kind: common.StackKindFast) u32 {
    const head = switch (kind) {
        .free => graph.free_groups_head.load(.acquire),
        .retired => graph.retired_groups_head.load(.acquire),
    };
    return @truncate(head);
}

pub fn groupMetaNextFast(graph: *const graph_core.GraphCore, group_index: u32) !u32 {
    if (group_index >= graph.group_count) return error.CorruptGraph;
    const page_index = page_ops.pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    const raw = graph.edge_block_group_meta_pages[@intCast(page_index)].load(.acquire);
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_GROUPS_PER_PAGE];
    return page[page_ops.slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)].next.load(.acquire);
}

pub fn populateGroupStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
) !void {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var current = groupStackHeadIndexFast(graph, kind);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) {
        if (visited >= limit) return error.CorruptGraph;
        visited += 1;
        if (!common.bitmapSet(bitmap, current)) return error.CorruptGraph;
        current = try groupMetaNextFast(graph, current);
    }
}
