const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const common = @import("common.zig");
const shared = @import("edge_shared.zig");
const side_runs = @import("../side_runs.zig");

pub fn ensureTailCowGroupConstraint(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    if (prepared.old_block == null) return;
    if (side_adj.block_count <= 1) return;
    if (side_adj.group_count < constants.MAX_GROUPS_PER_NODE) return;

    if (side_adj.group_count == 0) return;
    const tail_group = page_ops.groupAtConst(graph, side_adj.first_group + side_adj.group_count - 1);
    if (tail_group.count > 1) return error.RepairRequired;
}

pub fn appendPreparedBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !bool {
    if (side_adj.group_count == 0) {
        if (prepared.new_block == side_adj.first_block + side_adj.block_count) {
            side_adj.block_count += 1;
            return true;
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
        return true;
    }

    if (side_adj.block_count == 1) {
        const group = page_ops.groupAtConst(graph, side_adj.first_group);
        if (prepared.new_block == group.start + 1) {
            side_adj.first_block = group.start;
            side_adj.block_count = 2;
            side_adj.group_count = 0;
            side_adj.first_group = 0;
            return true;
        }
    }

    const tail_group = page_ops.groupAtConst(graph, side_adj.first_group + side_adj.group_count - 1);
    if (prepared.new_block == tail_group.start + tail_group.count) {
        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count, scratch);
        const last_group = page_ops.groupAt(graph, cloned_first_group + side_adj.group_count - 1);
        side_adj.first_group = cloned_first_group;
        last_group.count += 1;
        side_adj.block_count += 1;
        return true;
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return false;

    const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count + 1, scratch);
    page_ops.groupAt(graph, cloned_first_group + side_adj.group_count).* = .{
        .start = prepared.new_block,
        .next = constants.END_OF_CHAIN,
        .count = 1,
    };
    side_adj.first_group = cloned_first_group;
    side_adj.group_count += 1;
    side_adj.block_count += 1;
    return true;
}

pub fn replaceTailBlock(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !bool {
    if (side_adj.group_count == 0) {
        if (side_adj.block_count == 1) {
            side_adj.first_block = prepared.new_block;
            return true;
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
        return true;
    }

    if (side_adj.block_count == 1) {
        side_adj.first_block = prepared.new_block;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return true;
    }

    const tail_group = page_ops.groupAtConst(graph, side_adj.first_group + side_adj.group_count - 1);
    if (tail_group.count == 1) {
        const cloned_first_group = try side_runs.cloneGroupedRuns(graph, side_adj, side_adj.group_count, scratch);
        const last_group = page_ops.groupAt(graph, cloned_first_group + side_adj.group_count - 1);
        side_adj.first_group = cloned_first_group;
        last_group.start = prepared.new_block;
        return true;
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return false;

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
    return true;
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
