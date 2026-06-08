const std = @import("std");
const sorted_rebuild = @import("sorted_rebuild.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");

const ReverseSourceMatchCount = struct {
    source_idx: u32,
    total: usize = 0,
};

fn countReverseSourceMatch(
    graph: *const graph_core.GraphCore,
    count: *ReverseSourceMatchCount,
    block_idx: u32,
    slot: u7,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    if (block.sources[slot] == count.source_idx) count.total += 1;
}
pub const ForwardTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
    removed_count: usize,
};

pub const ReverseTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
};

pub fn rebuildForwardLive(
    graph: *graph_core.GraphCore,
    node_idx: u32,
    published_adj: types.NodeAdj,
    allocs: *mutation_common.MutationScratch,
) !ForwardTombstoneCompaction {
    var result = try sorted_rebuild.sortedRebuildForward(
        graph,
        published_adj.first_block_fwd,
        published_adj.block_count_fwd,
        published_adj.group_count_fwd,
        published_adj.first_group_fwd,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);

    allocs.adoptBlocks(graph.allocator, .fwd, result.new_blocks.items) catch |err| {
        for (result.new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, .fwd);
        return err;
    };

    var staging_adj = published_adj;
    {
        var tmp: types.SideAdj = undefined;
        try side_adj.buildSideFromBlocks(&tmp, graph, result.new_blocks.items, allocs);
        staging_adj.first_block_fwd = tmp.first_block;
        staging_adj.block_count_fwd = tmp.block_count;
        staging_adj.group_count_fwd = tmp.group_count;
        staging_adj.first_group_fwd = tmp.first_group;
    }
    debt_mod.updateRepairDebt(graph, &staging_adj, node_idx, .fwd);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after, .removed_count = 0 };
}

pub fn countReverseMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_idx: u32,
) !usize {
    var count = ReverseSourceMatchCount{ .source_idx = source_idx };
    try side_adj.forEachSlotInSide(
        graph,
        .{
            .first_block = first_block,
            .block_count = block_count,
            .group_count = group_count,
            .first_group = first_group,
        },
        .rev,
        &count,
        countReverseSourceMatch,
    );
    return count.total;
}

pub fn prepareReverseDrop(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_idx: u32,
    allocator: std.mem.Allocator,
) !sorted_rebuild.SortedRebuildResult {
    const matches = try countReverseMatches(graph, first_block, block_count, group_count, first_group, source_idx);
    if (!graph.multigraph_enabled and matches != 1) return error.CorruptGraph;
    if (matches == 0) return error.CorruptGraph;
    return sorted_rebuild.sortedRebuildReverse(graph, first_block, block_count, group_count, first_group, source_idx, allocator);
}

pub fn rebuildReverseDrop(
    graph: *graph_core.GraphCore,
    destination_idx: u32,
    published_adj: types.NodeAdj,
    source_idx: u32,
    allocs: *mutation_common.MutationScratch,
) !ReverseTombstoneCompaction {
    var result = try prepareReverseDrop(
        graph,
        published_adj.first_block_rev,
        published_adj.block_count_rev,
        published_adj.group_count_rev,
        published_adj.first_group_rev,
        source_idx,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);

    allocs.adoptBlocks(graph.allocator, .rev, result.new_blocks.items) catch |err| {
        for (result.new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, .rev);
        return err;
    };

    var staging_adj = published_adj;
    {
        var tmp: types.SideAdj = undefined;
        try side_adj.buildSideFromBlocks(&tmp, graph, result.new_blocks.items, allocs);
        staging_adj.first_block_rev = tmp.first_block;
        staging_adj.block_count_rev = tmp.block_count;
        staging_adj.group_count_rev = tmp.group_count;
        staging_adj.first_group_rev = tmp.first_group;
    }
    debt_mod.updateRepairDebt(graph, &staging_adj, destination_idx, .rev);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after };
}
