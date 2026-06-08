const std = @import("std");
const adjacency = @import("../adjacency/mod.zig");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const rcu = @import("../concurrency/rcu.zig");

pub const TraversalState = struct {
    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,
};

pub fn buildTraversalState(side_adj: types.SideAdj) TraversalState {
    if (side_adj.block_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = 0,
            .blocks_remaining = 0,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    if (side_adj.group_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = side_adj.first_block,
            .blocks_remaining = side_adj.block_count,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    return .{
        .contiguous_mode = false,
        .current_block_index = 0,
        .blocks_remaining = 0,
        .current_group_index = side_adj.first_group,
    };
}

pub fn validateReadSideQuick(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const block_limit = switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };

    if (side_adj.block_count == 0) {
        if (side_adj.group_count != 0) return error.CorruptGraph;
        return;
    }

    if (side_adj.group_count == 0) {
        if (side_adj.first_block >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, side_adj.first_block, side_adj.block_count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        return;
    }

    if (side_adj.first_group >= graph.group_count) return error.CorruptGraph;
}

pub fn primeGroupedTraversal(iterator: anytype, graph: *const graph_core.GraphCore) void {
    if (iterator.contiguous_mode) return;
    if (iterator.current_group_index == constants.END_OF_CHAIN) return;
    if (iterator.current_group_index >= graph.group_count) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return;
    }

    const first_group = page_ops.groupAtConst(graph, iterator.current_group_index);
    iterator.current_block_index = first_group.start;
    iterator.blocks_remaining = first_group.count;
}

pub fn advanceToNextGroup(iterator: anytype, graph: *const graph_core.GraphCore) bool {
    if (iterator.contiguous_mode) return false;
    if (iterator.current_group_index == constants.END_OF_CHAIN) return false;
    if (iterator.current_group_index >= graph.group_count) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return false;
    }

    if (iterator.groups_visited + 1 >= iterator.group_count_bound) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return false;
    }

    iterator.current_group_index += 1;
    iterator.groups_visited += 1;

    const next_group = page_ops.groupAtConst(graph, iterator.current_group_index);
    iterator.current_block_index = next_group.start;
    iterator.blocks_remaining = next_group.count;
    return true;
}

pub fn candidateRemoved(iterator: anytype, graph: *const graph_core.GraphCore, candidate_index: u32) bool {
    if (candidate_index >= graph.publishedNodeCount()) return true;
    const page_index = page_ops.pageOf(candidate_index, constants.NODES_PER_PAGE);
    if (iterator.cached_node_page == null or iterator.cached_node_page_index != page_index) {
        iterator.cached_node_page = page_ops.nodePageAtConst(graph, page_index);
        iterator.cached_node_page_index = page_index;
    }

    const slot_index = page_ops.slotOf(candidate_index, constants.NODES_PER_PAGE);
    return iterator.cached_node_page.?[slot_index].loadPublishedMeta().removed;
}

pub fn deinitReader(iterator: anytype, graph: *const graph_core.GraphCore) void {
    if (!iterator.reader_active) return;

    switch (rcu.beginCloseReaderToken(iterator.reader_token)) {
        .inactive => {},
        .pending => {},
        .finalize => rcu.finalizeReaderExit(@constCast(graph), iterator.reader_token),
    }
    iterator.reader_active = false;
}
