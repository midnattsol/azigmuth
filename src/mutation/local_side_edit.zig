const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency.zig");
const common = @import("common.zig");
const shared = @import("edge_shared.zig");
const local_repair = @import("local_repair.zig");

pub fn ensureTailCowGroupConstraint(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    try local_repair.ensureTailCowGroupConstraint(graph, side_adj, prepared);
}

pub fn tryApplyPreparedAppendFast(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !?shared.AppliedAppend {
    if (side_adj.block_count == 0) {
        side_adj.first_block = prepared.new_block;
        side_adj.block_count = 1;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return .{ .block_idx = prepared.new_block };
    }

    if (@as(u22, side_adj.block_count) >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;

    if (prepared.old_block == null) return try local_repair.appendPreparedBlock(graph, side_adj, prepared, side, scratch);
    return try local_repair.replaceTailBlock(graph, side_adj, prepared, side, scratch);
}

pub fn tryApplyRemovalPlanFast(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    found_block_idx: u32,
    new_block: u32,
    new_live: u7,
    scratch: *common.MutationScratch,
) !bool {
    if (published_side.block_count == 1) {
        if (new_live == 0) {
            staging_side.first_block = 0;
            staging_side.block_count = 0;
            staging_side.group_count = 0;
            staging_side.first_group = 0;
            return true;
        }

        staging_side.first_block = new_block;
        staging_side.block_count = 1;
        staging_side.group_count = 0;
        staging_side.first_group = 0;
        return true;
    }

    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, published_side)) orelse return error.CorruptGraph;
    if (found_block_idx != tail_idx) return false;
    return try local_repair.removeTailBlock(graph, staging_side, published_side, new_block, new_live, scratch);
}

pub fn isRemovalLocal(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    found_block_idx: u32,
) !bool {
    if (published_side.block_count <= 1) return true;
    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, published_side)) orelse return error.CorruptGraph;
    return found_block_idx == tail_idx;
}
