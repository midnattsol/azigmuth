const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");

pub fn appendBlockShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    block_idx: u32,
    comptime side: common.Side,
) !void {
    if (!common.blockExists(graph, block_idx, side)) return;

    const alive_count = common.blockAlive(graph, block_idx, side);
    const id_block = if (side == .fwd and graph.multigraph_enabled)
        page_ops.edgeBlockFwdIdsAtConst(graph, block_idx)
    else
        null;

    if (alive_count > constants.EDGES_PER_BLOCK) {
        try violations.append(allocator, .{ .mask_bit_out_of_range = .{ .node = node_id, .block = block_idx } });
        return;
    }

    var prev_key: ?u32 = null;
    var prev_edge_id: u32 = 0;
    for (0..alive_count) |slot| {
        const key = common.blockKey(graph, block_idx, slot, side);
        if (key >= graph.publishedNodeCount()) {
            try violations.append(allocator, .{ .invalid_destination = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot), .destination = key } });
        }

        if (id_block) |fwd_ids| {
            const edge_id = fwd_ids.ids[slot];
            if (edge_id == 0) {
                try violations.append(allocator, .{ .invalid_edge_id = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot), .edge_id = edge_id } });
            }
            if (prev_key) |previous| {
                if (key < previous or (key == previous and edge_id <= prev_edge_id)) {
                    try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot) } });
                }
            }
            prev_edge_id = edge_id;
        } else if (prev_key) |previous| {
            if (key < previous or (!graph.multigraph_enabled and key == previous)) {
                try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot) } });
            }
        }

        prev_key = key;
    }
}
