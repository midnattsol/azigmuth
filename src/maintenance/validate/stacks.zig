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
    return page_ops.stackHeadIndex(head);
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
    return page_ops.stackMetaNext(&page[page_ops.slotOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE)]);
}

pub fn populateStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
    comptime side: common.Side,
) !void {
    const limit = common.allocatedBlockCount(graph, side);
    const Links = struct {
        graph: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), block_idx: u32) !u32 {
            return blockMetaNextFast(self.graph, block_idx, side);
        }
    };
    const Visitor = struct {
        bitmap: []u64,
        limit: u32,
        visited: u32 = 0,

        pub fn visit(self: *@This(), block_idx: u32) !void {
            if (self.visited >= self.limit) return error.CorruptGraph;
            self.visited += 1;
            if (!common.bitmapSet(self.bitmap, block_idx)) return error.CorruptGraph;
        }
    };
    var visitor = Visitor{ .bitmap = bitmap, .limit = limit };
    try page_ops.walkDetachedIndexStack(blockStackHeadIndex(graph, kind, side), Links{ .graph = graph }, &visitor);
}

pub fn groupSpanStackHeadIndexFast(graph: *const graph_core.GraphCore, comptime kind: common.StackKindFast, span_count: u16) u32 {
    const span_idx: usize = @intCast(span_count - 1);
    const head = switch (kind) {
        .free => graph.free_group_spans_head[span_idx].load(.acquire),
        .retired => graph.retired_group_spans_head[span_idx].load(.acquire),
    };
    return page_ops.stackHeadIndex(head);
}

pub fn groupMetaNextFast(graph: *const graph_core.GraphCore, group_idx: u32) !u32 {
    if (group_idx >= graph.loadGroupCount()) return error.CorruptGraph;
    const page_idx = page_ops.pageOf(group_idx, constants.EDGE_GROUPS_PER_PAGE);
    const raw = graph.edge_block_group_meta_pages.load(page_idx);
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_GROUPS_PER_PAGE];
    return page_ops.stackMetaNext(&page[page_ops.slotOf(group_idx, constants.EDGE_GROUPS_PER_PAGE)]);
}

pub fn populateGroupStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
) !void {
    const limit = graph.loadGroupCount();
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        const Links = struct {
            graph: *const graph_core.GraphCore,

            pub fn nextIndex(self: @This(), group_idx: u32) !u32 {
                return groupMetaNextFast(self.graph, group_idx);
            }
        };
        const Visitor = struct {
            bitmap: []u64,
            limit: u32,
            span_count: u16,
            visited: u32 = 0,

            pub fn visit(self: *@This(), first_group_idx: u32) !void {
                if (self.visited >= self.limit) return error.CorruptGraph;
                self.visited += 1;
                for (first_group_idx..first_group_idx + self.span_count) |group_idx_usize| {
                    const group_idx: u32 = @intCast(group_idx_usize);
                    if (!common.bitmapSet(self.bitmap, group_idx)) return error.CorruptGraph;
                }
            }
        };
        var visitor = Visitor{ .bitmap = bitmap, .limit = limit, .span_count = span_count };
        try page_ops.walkDetachedIndexStack(groupSpanStackHeadIndexFast(graph, kind, span_count), Links{ .graph = graph }, &visitor);
    }
}
