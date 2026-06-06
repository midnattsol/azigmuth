//! Fast-path validation entry point.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");

const common = @import("common.zig");
const shape = @import("shape.zig");
const sums = @import("sums.zig");
const stacks = @import("stacks.zig");
const ownership = @import("ownership.zig");
const consistency = @import("consistency.zig");

pub fn validate(graph: *const graph_core.GraphCore) !void {
    const reader_token = try common.readerEnter(graph);
    defer common.readerExit(graph, reader_token);

    const node_count = graph.publishedNodeCount();
    var total_visible_forward: u64 = 0;
    var total_visible_reverse: u64 = 0;
    var owned_forward_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;
    var owned_reverse_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;
    var free_forward_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;
    var free_reverse_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;
    var retired_forward_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;
    var retired_reverse_blocks: [common.TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_BLOCK_BITMAP_WORDS;

    var owned_groups: [common.TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_GROUP_BITMAP_WORDS;
    var free_groups: [common.TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_GROUP_BITMAP_WORDS;
    var retired_groups: [common.TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** common.TRACKED_GROUP_BITMAP_WORDS;

    try stacks.populateStackBitmapFast(graph, free_forward_blocks[0..], .free, .fwd);
    try stacks.populateStackBitmapFast(graph, free_reverse_blocks[0..], .free, .rev);
    try stacks.populateStackBitmapFast(graph, retired_forward_blocks[0..], .retired, .fwd);
    try stacks.populateStackBitmapFast(graph, retired_reverse_blocks[0..], .retired, .rev);
    try stacks.populateGroupStackBitmapFast(graph, free_groups[0..], .free);
    try stacks.populateGroupStackBitmapFast(graph, retired_groups[0..], .retired);

    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const node_buffer = page_ops.nodeAtConst(graph, .{ .index = node_id });
        const adjacency = node_buffer.publishedAdj();

        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .fwd);
        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .rev);
        total_visible_forward += sums.sumVisibleAdjacency(graph, adjacency, .fwd);
        total_visible_reverse += sums.sumVisibleAdjacency(graph, adjacency, .rev);
        try ownership.validateAdjacencyOwnershipAndLayoutFast(graph, adjacency, owned_forward_blocks[0..], free_forward_blocks[0..], retired_forward_blocks[0..], owned_groups[0..], free_groups[0..], retired_groups[0..], .fwd);
        try ownership.validateAdjacencyOwnershipAndLayoutFast(graph, adjacency, owned_reverse_blocks[0..], free_reverse_blocks[0..], retired_reverse_blocks[0..], owned_groups[0..], free_groups[0..], retired_groups[0..], .rev);
        try shape.validateOccupancyFast(graph, adjacency, .fwd);
        try shape.validateOccupancyFast(graph, adjacency, .rev);
        try consistency.validateForwardEdgeIdsFast(graph, node_buffer, node_id, adjacency);
        try consistency.validateForwardConsistencyFast(graph, node_id, adjacency);
        try consistency.validateReverseConsistencyFast(graph, node_id, adjacency);

        if (adjacency.flags.removed) {
            const meta = node_buffer.loadPublishedMeta();
            if (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or meta.degree_fwd != 0) {
                return error.CorruptGraph;
            }
            if (meta.degree_rev != 0) {
                return error.CorruptGraph;
            }
            if (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev) {
                return error.CorruptGraph;
            }
        }

        const fwd_visible = sums.sumVisibleAdjacency(graph, adjacency, .fwd);
        const rev_visible = sums.sumVisibleAdjacency(graph, adjacency, .rev);
        if (!adjacency.flags.removed) {
            const meta = node_buffer.loadPublishedMeta();
            if (@as(usize, meta.degree_fwd) != fwd_visible) {
                return error.CorruptGraph;
            }
            if (@as(usize, meta.degree_rev) != rev_visible) {
                return error.CorruptGraph;
            }
            if (!adjacency.flags.needs_repair_fwd and common.forwardHasTombstone(graph, adjacency)) {
                return error.CorruptGraph;
            }
        }
    }

    try ownership.validateRepairDebtFast(graph, node_count);

    {
        const fwd_limit = common.allocatedBlockCount(graph, .fwd);
        for (0..fwd_limit) |block_index| {
            if (!common.bitmapIsSet(owned_forward_blocks[0..], @intCast(block_index)) and
                !common.bitmapIsSet(free_forward_blocks[0..], @intCast(block_index)) and
                !common.bitmapIsSet(retired_forward_blocks[0..], @intCast(block_index)))
            {
                return error.CorruptGraph;
            }
        }
    }
    {
        const rev_limit = common.allocatedBlockCount(graph, .rev);
        for (0..rev_limit) |block_index| {
            if (!common.bitmapIsSet(owned_reverse_blocks[0..], @intCast(block_index)) and
                !common.bitmapIsSet(free_reverse_blocks[0..], @intCast(block_index)) and
                !common.bitmapIsSet(retired_reverse_blocks[0..], @intCast(block_index)))
            {
                return error.CorruptGraph;
            }
        }
    }
    {
        const group_limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
        for (0..group_limit) |group_index| {
            if (!common.bitmapIsSet(owned_groups[0..], @intCast(group_index)) and
                !common.bitmapIsSet(free_groups[0..], @intCast(group_index)) and
                !common.bitmapIsSet(retired_groups[0..], @intCast(group_index)))
            {
                return error.CorruptGraph;
            }
        }
    }

    if (total_visible_forward != total_visible_reverse) return error.CorruptGraph;
    if (total_visible_forward != graph.edge_count.load(.acquire)) return error.CorruptGraph;
}
