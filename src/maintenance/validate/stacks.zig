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

pub fn blockReclamationNextFast(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) !u32 {
    if (!common.blockExists(graph, block_idx, side)) return error.CorruptGraph;
    const page_idx = page_ops.pageOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE);
    const raw = switch (side) {
        .fwd => graph.edge_blocks_fwd_reclamation_pages.load(page_idx),
        .rev => graph.edge_blocks_rev_reclamation_pages.load(page_idx),
    };
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.ReclamationEntry = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_BLOCKS_PER_PAGE];
    return page_ops.reclamationNext(&page[page_ops.slotOf(block_idx, constants.EDGE_BLOCKS_PER_PAGE)]);
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
            return blockReclamationNextFast(self.graph, block_idx, side);
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

pub fn segmentSlotStackHeadIndexFast(graph: *const graph_core.GraphCore, comptime kind: common.StackKindFast, slot_count: u16) u32 {
    const slot_count_idx: usize = @intCast(slot_count - 1);
    const head = switch (kind) {
        .free => graph.free_segment_slots_head[slot_count_idx].load(.acquire),
        .retired => graph.retired_segment_slots_head[slot_count_idx].load(.acquire),
    };
    return page_ops.stackHeadIndex(head);
}

pub fn segmentReclamationNextFast(graph: *const graph_core.GraphCore, segment_idx: u32) !u32 {
    if (segment_idx >= graph.loadSegmentCount()) return error.CorruptGraph;
    const page_idx = page_ops.pageOf(segment_idx, constants.EDGE_SEGMENTS_PER_PAGE);
    const raw = graph.edge_block_segment_reclamation_pages.load(page_idx);
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.ReclamationEntry = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_SEGMENTS_PER_PAGE];
    return page_ops.reclamationNext(&page[page_ops.slotOf(segment_idx, constants.EDGE_SEGMENTS_PER_PAGE)]);
}

pub fn populateSegmentStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: common.StackKindFast,
) !void {
    const limit = graph.loadSegmentCount();
    var slot_count: u16 = 1;
    while (slot_count <= constants.MAX_SEGMENTS_PER_NODE) : (slot_count += 1) {
        const Links = struct {
            graph: *const graph_core.GraphCore,

            pub fn nextIndex(self: @This(), segment_idx: u32) !u32 {
                return segmentReclamationNextFast(self.graph, segment_idx);
            }
        };
        const Visitor = struct {
            bitmap: []u64,
            limit: u32,
            slot_count: u16,
            visited: u32 = 0,

            pub fn visit(self: *@This(), first_segment_idx: u32) !void {
                if (self.visited >= self.limit) return error.CorruptGraph;
                self.visited += 1;
                for (first_segment_idx..first_segment_idx + self.slot_count) |segment_idx_usize| {
                    const segment_idx: u32 = @intCast(segment_idx_usize);
                    if (!common.bitmapSet(self.bitmap, segment_idx)) return error.CorruptGraph;
                }
            }
        };
        var visitor = Visitor{ .bitmap = bitmap, .limit = limit, .slot_count = slot_count };
        try page_ops.walkDetachedIndexStack(segmentSlotStackHeadIndexFast(graph, kind, slot_count), Links{ .graph = graph }, &visitor);
    }
}
