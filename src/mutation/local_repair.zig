const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const adjacency = @import("../adjacency/mod.zig");
const page_ops = @import("../storage/page_ops.zig");
const common = @import("common.zig");
const shared = @import("edge/shared.zig");
const side_runs = @import("../adjacency/runs.zig");

pub fn ensureTailCowGroupConstraint(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    _ = graph;
    _ = side_adj;
    _ = prepared;
}

fn copyBlock(graph: *graph_core.GraphCore, source_block_idx: u32, destination_block_idx: u32, comptime side: adjacency.AdjSide) void {
    switch (side) {
        .fwd => {
            page_ops.edgeBlockAt(graph, destination_block_idx, .fwd).* = page_ops.edgeBlockAtConst(graph, source_block_idx, .fwd).*;
            page_ops.setBlockLiveCount(graph, destination_block_idx, .fwd, page_ops.blockLiveCount(graph, source_block_idx, .fwd));
            if (graph.multigraph_enabled) {
                page_ops.edgeBlockFwdIdsAt(graph, destination_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, source_block_idx).*;
            }
        },
        .rev => {
            page_ops.edgeBlockAt(graph, destination_block_idx, .rev).* = page_ops.edgeBlockAtConst(graph, source_block_idx, .rev).*;
            page_ops.setBlockLiveCount(graph, destination_block_idx, .rev, page_ops.blockLiveCount(graph, source_block_idx, .rev));
        },
    }
}

fn replaceTailSuffixWithFreshSpan(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
    discarded_block_idx: u32,
    append_new_block: bool,
) !u32 {
    if (side_adj.group_count == 0) return error.RepairRequired;
    if (side_adj.group_count < 2) return error.RepairRequired;

    const suffix_group_idx = side_adj.group_count - 2;
    const prefix_group_count = side_adj.group_count - 1;
    const penultimate_run = side_runs.runAt(graph, side_adj.*, suffix_group_idx) orelse return error.CorruptGraph;
    const tail_run = side_runs.runAt(graph, side_adj.*, suffix_group_idx + 1) orelse return error.CorruptGraph;

    scratch.freeTrackedBlock(graph, side, discarded_block_idx);

    const new_run_block_count: u32 = penultimate_run.count + tail_run.count + @as(u32, if (append_new_block) 1 else 0);
    const first_block_idx = try scratch.allocFreshBlockSpan(graph, side, new_run_block_count);

    var block_offset: u32 = 0;
    while (block_offset < penultimate_run.count) : (block_offset += 1) {
        copyBlock(graph, penultimate_run.start + block_offset, first_block_idx + block_offset, side);
    }
    while (block_offset < penultimate_run.count + tail_run.count) : (block_offset += 1) {
        const tail_offset = block_offset - penultimate_run.count;
        copyBlock(graph, tail_run.start + tail_offset, first_block_idx + block_offset, side);
    }

    const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, prefix_group_count, scratch);
    const tail_group = page_ops.groupAt(graph, cloned_first_group + prefix_group_count - 1);
    tail_group.start = first_block_idx;
    tail_group.count = new_run_block_count;
    side_adj.first_group = cloned_first_group;
    side_adj.group_count = prefix_group_count;
    if (append_new_block) side_adj.block_count += 1;

    return first_block_idx + new_run_block_count - 1;
}

pub fn appendPreparedBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !?shared.AppliedAppend {
    if (side_adj.group_count == 0) {
        if (prepared.new_block == side_adj.first_block + side_adj.block_count) {
            side_adj.block_count += 1;
            return .{ .block_idx = prepared.new_block };
        }

        const first_group_idx = try scratch.allocGroupSpan(graph, 2);
        page_ops.groupAt(graph, first_group_idx).* = .{
            .start = side_adj.first_block,
            .next = constants.END_OF_CHAIN,
            .count = side_adj.block_count,
        };
        page_ops.groupAt(graph, first_group_idx + 1).* = .{
            .start = prepared.new_block,
            .next = constants.END_OF_CHAIN,
            .count = 1,
        };
        side_adj.first_group = first_group_idx;
        side_adj.group_count = 2;
        side_adj.block_count += 1;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.block_count == 1) {
        const group = page_ops.groupAtConst(graph, side_adj.first_group);
        if (prepared.new_block == group.start + 1) {
            side_adj.first_block = group.start;
            side_adj.block_count = 2;
            side_adj.group_count = 0;
            side_adj.first_group = 0;
            return .{ .block_idx = prepared.new_block };
        }
    }

    const tail_group = page_ops.groupAtConst(graph, side_adj.first_group + side_adj.group_count - 1);
    if (prepared.new_block == tail_group.start + tail_group.count) {
        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count, scratch);
        const last_group = page_ops.groupAt(graph, cloned_first_group + side_adj.group_count - 1);
        side_adj.first_group = cloned_first_group;
        last_group.count += 1;
        side_adj.block_count += 1;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) {
        const total_runs = side_runs.runCount(side_adj.*);
        const penultimate_run = side_runs.runAt(graph, side_adj.*, total_runs - 2) orelse return error.CorruptGraph;
        const tail_run = side_runs.runAt(graph, side_adj.*, total_runs - 1) orelse return error.CorruptGraph;
        return .{
            .block_idx = try replaceTailSuffixWithFreshSpan(graph, side_adj, side, scratch, prepared.new_block, true),
            .retired_runs = .{ penultimate_run, tail_run },
            .retired_run_count = 2,
        };
    }

    const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count + 1, scratch);
    page_ops.groupAt(graph, cloned_first_group + side_adj.group_count).* = .{
        .start = prepared.new_block,
        .next = constants.END_OF_CHAIN,
        .count = 1,
    };
    side_adj.first_group = cloned_first_group;
    side_adj.group_count += 1;
    side_adj.block_count += 1;
    return .{ .block_idx = prepared.new_block };
}

pub fn replaceTailBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !?shared.AppliedAppend {
    if (side_adj.group_count == 0) {
        if (side_adj.block_count == 1) {
            side_adj.first_block = prepared.new_block;
            return .{ .block_idx = prepared.new_block };
        }

        const first_group_idx = try scratch.allocGroupSpan(graph, 2);
        page_ops.groupAt(graph, first_group_idx).* = .{
            .start = side_adj.first_block,
            .next = constants.END_OF_CHAIN,
            .count = side_adj.block_count - 1,
        };
        page_ops.groupAt(graph, first_group_idx + 1).* = .{
            .start = prepared.new_block,
            .next = constants.END_OF_CHAIN,
            .count = 1,
        };
        side_adj.first_group = first_group_idx;
        side_adj.group_count = 2;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.block_count == 1) {
        side_adj.first_block = prepared.new_block;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return .{ .block_idx = prepared.new_block };
    }

    const tail_group = page_ops.groupAtConst(graph, side_adj.first_group + side_adj.group_count - 1);
    if (tail_group.count == 1) {
        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count, scratch);
        const last_group = page_ops.groupAt(graph, cloned_first_group + side_adj.group_count - 1);
        side_adj.first_group = cloned_first_group;
        last_group.start = prepared.new_block;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) {
        const total_runs = side_runs.runCount(side_adj.*);
        const penultimate_run = side_runs.runAt(graph, side_adj.*, total_runs - 2) orelse return error.CorruptGraph;
        const tail_run = side_runs.runAt(graph, side_adj.*, total_runs - 1) orelse return error.CorruptGraph;
        return .{
            .block_idx = try replaceTailSuffixWithFreshSpan(graph, side_adj, side, scratch, prepared.new_block, false),
            .retire_prepared_old_block = false,
            .retired_runs = .{ penultimate_run, tail_run },
            .retired_run_count = 2,
        };
    }

    const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count + 1, scratch);
    const cloned_tail_group = page_ops.groupAt(graph, cloned_first_group + side_adj.group_count - 1);
    page_ops.groupAt(graph, cloned_first_group + side_adj.group_count).* = .{
        .start = prepared.new_block,
        .next = constants.END_OF_CHAIN,
        .count = 1,
    };
    cloned_tail_group.count -= 1;
    side_adj.first_group = cloned_first_group;
    side_adj.group_count += 1;
    return .{ .block_idx = prepared.new_block };
}

pub fn removeTailBlock(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    new_block: u32,
    new_live: u7,
    scratch: *common.MutationScratch,
) !bool {
    if (published_side.group_count == 0) {
        if (new_live == 0) {
            staging_side.block_count -= 1;
            return true;
        }

        const first_group_idx = try scratch.allocGroupSpan(graph, 2);
        page_ops.groupAt(graph, first_group_idx).* = .{
            .start = published_side.first_block,
            .next = constants.END_OF_CHAIN,
            .count = published_side.block_count - 1,
        };
        page_ops.groupAt(graph, first_group_idx + 1).* = .{
            .start = new_block,
            .next = constants.END_OF_CHAIN,
            .count = 1,
        };
        staging_side.first_group = first_group_idx;
        staging_side.group_count = 2;
        return true;
    }

    const tail_group = page_ops.groupAtConst(graph, published_side.first_group + published_side.group_count - 1);
    if (new_live == 0) {
        if (tail_group.count > 1) {
            if (published_side.group_count == 1) {
                staging_side.first_block = tail_group.start;
                staging_side.group_count = 0;
                staging_side.first_group = 0;
            } else {
                const cloned_first_group = try side_runs.cloneGroupedRuns(graph, published_side, published_side.group_count, scratch);
                const cloned_tail_group = page_ops.groupAt(graph, cloned_first_group + published_side.group_count - 1);
                cloned_tail_group.count -= 1;
                staging_side.first_group = cloned_first_group;
            }
            staging_side.block_count -= 1;
            return true;
        }

        if (published_side.group_count == 1) return false;

        if (published_side.group_count == 2) {
            const remaining_group = page_ops.groupAtConst(graph, published_side.first_group);
            staging_side.first_block = remaining_group.start;
            staging_side.group_count = 0;
            staging_side.first_group = 0;
            staging_side.block_count -= 1;
            return true;
        }

        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, published_side, published_side.group_count - 1, scratch);
        staging_side.first_group = cloned_first_group;
        staging_side.group_count -= 1;
        staging_side.block_count -= 1;
        return true;
    }

    if (tail_group.count == 1) {
        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, published_side, published_side.group_count, scratch);
        const cloned_tail_group = page_ops.groupAt(graph, cloned_first_group + published_side.group_count - 1);
        cloned_tail_group.start = new_block;
        staging_side.first_group = cloned_first_group;
        return true;
    }

    if (published_side.group_count >= constants.MAX_GROUPS_PER_NODE) return false;

    const cloned_first_group = try side_runs.cloneGroupedRuns(graph, published_side, published_side.group_count + 1, scratch);
    const cloned_tail_group = page_ops.groupAt(graph, cloned_first_group + published_side.group_count - 1);
    page_ops.groupAt(graph, cloned_first_group + published_side.group_count).* = .{
        .start = new_block,
        .next = constants.END_OF_CHAIN,
        .count = 1,
    };
    cloned_tail_group.count -= 1;
    staging_side.first_group = cloned_first_group;
    staging_side.group_count += 1;
    return true;
}
