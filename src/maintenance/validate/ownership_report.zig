const common = @import("common.zig");
const ownership_sets = @import("ownership_sets.zig");
const block_shape = @import("block_shape.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");

pub fn appendOwnershipAndShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    owned_blocks: *std.DynamicBitSetUnmanaged,
    free_blocks: *const std.DynamicBitSetUnmanaged,
    retired_blocks: *const std.DynamicBitSetUnmanaged,
    node_id: u32,
    blocks: []const common.TraversedBlock,
    comptime side: common.Side,
) !void {
    const tail_block_idx = if (blocks.len > 0) blocks[blocks.len - 1].block_index else constants.END_OF_CHAIN;

    for (blocks) |traversed_block| {
        const block_idx = traversed_block.block_index;
        if (!common.blockExists(graph, block_idx, side)) continue;

        if (!ownership_sets.markOwnedBlock(owned_blocks, block_idx)) {
            try violations.append(allocator, .{ .block_double_owned = .{ .block = block_idx } });
        }

        const bit_idx: usize = @intCast(block_idx);
        if (bit_idx < free_blocks.bit_length and free_blocks.isSet(bit_idx)) {
            try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = block_idx } });
        }
        if (bit_idx < retired_blocks.bit_length and retired_blocks.isSet(bit_idx)) {
            try violations.append(allocator, .{ .retired_block_reachable = .{ .block = block_idx, .node = node_id } });
        }

        try block_shape.appendBlockShapeViolations(graph, allocator, violations, node_id, block_idx, side);

        const live_count = @popCount(common.blockMask(graph, block_idx, side));
        const non_tail_underfull = blocks.len > 1 and block_idx != tail_block_idx and live_count < constants.MIN_OCCUPANCY;
        if (non_tail_underfull) {
            try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = block_idx, .occupancy = @intCast(live_count) } });
        }
    }
}
