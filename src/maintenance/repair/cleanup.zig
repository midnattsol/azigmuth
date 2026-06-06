const std = @import("std");
const sorted_rebuild = @import("sorted_rebuild.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
pub const ForwardTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
    removed_count: usize,
};

pub const ReverseTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    live_after: usize,
};

pub fn rebuildForwardWithoutRemovedDestinations(
    graph: *graph_core.GraphCore,
    node_index: u32,
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

    try allocs.adoptBlocks(graph.allocator, .fwd, result.new_blocks.items);

    var staging_adj = published_adj;
    {
        var tmp: types.SideAdj = undefined;
        try mutation_common.buildSideFromBlocks(&tmp, graph, result.new_blocks.items, allocs);
        staging_adj.first_block_fwd = tmp.first_block;
        staging_adj.block_count_fwd = tmp.block_count;
        staging_adj.group_count_fwd = tmp.group_count;
        staging_adj.first_group_fwd = tmp.first_group;
    }
    debt_mod.updateRepairDebt(graph, &staging_adj, node_index, .fwd);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after, .removed_count = 0 };
}

pub fn countReverseSourceMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_index: u32,
) !usize {
    var matches: usize = 0;
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) matches += 1;
            }
        }
    } else {
        try adjacency.validateSideAdjLayout(graph, .{
            .first_block = first_block,
            .block_count = block_count,
            .group_count = group_count,
            .first_group = first_group,
        });
        var group_idx = first_group;
        var rev_src_visited: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            rev_src_visited += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) matches += 1;
                }
            }
            group_idx = group.next;
        }
    }
    return matches;
}

pub fn prepareReverseWithoutSource(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    source_index: u32,
    allocator: std.mem.Allocator,
) !sorted_rebuild.SortedRebuildResult {
    const matches = try countReverseSourceMatches(graph, first_block, block_count, group_count, first_group, source_index);
    if (!graph.multigraph_enabled and matches != 1) return error.CorruptGraph;
    if (matches == 0) return error.CorruptGraph;
    return sorted_rebuild.sortedRebuildReverse(graph, first_block, block_count, group_count, first_group, source_index, allocator);
}

pub fn rebuildReverseWithoutSource(
    graph: *graph_core.GraphCore,
    destination_index: u32,
    published_adj: types.NodeAdj,
    source_index: u32,
    allocs: *mutation_common.MutationScratch,
) !ReverseTombstoneCompaction {
    var result = try prepareReverseWithoutSource(
        graph,
        published_adj.first_block_rev,
        published_adj.block_count_rev,
        published_adj.group_count_rev,
        published_adj.first_group_rev,
        source_index,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);

    try allocs.adoptBlocks(graph.allocator, .rev, result.new_blocks.items);

    var staging_adj = published_adj;
    {
        var tmp: types.SideAdj = undefined;
        try mutation_common.buildSideFromBlocks(&tmp, graph, result.new_blocks.items, allocs);
        staging_adj.first_block_rev = tmp.first_block;
        staging_adj.block_count_rev = tmp.block_count;
        staging_adj.group_count_rev = tmp.group_count;
        staging_adj.first_group_rev = tmp.first_group;
    }
    debt_mod.updateRepairDebt(graph, &staging_adj, destination_index, .rev);

    return .{ .staging_adj = staging_adj, .live_after = result.live_after };
}
