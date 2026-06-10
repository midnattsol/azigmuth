const std = @import("std");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const common = @import("../../../common.zig");

pub const ForwardRemovalResult = struct {
    new_side: types.SideAdj,
    removed: u32,
};

pub fn buildSideFromBlockList(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: []const u32,
) !types.SideAdj {
    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list, scratch);
    return new_side;
}

pub fn cloneForwardBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    page_ops.edgeBlockAt(graph, new_block_idx, .fwd).* = page_ops.edgeBlockAtConst(graph, block_idx, .fwd).*;
    if (graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(graph, new_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).*;
    }
    return new_block_idx;
}

pub fn cloneReverseBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .rev);
    page_ops.edgeBlockAt(graph, new_block_idx, .rev).* = page_ops.edgeBlockAtConst(graph, block_idx, .rev).*;
    return new_block_idx;
}
