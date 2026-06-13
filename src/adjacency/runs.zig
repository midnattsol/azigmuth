const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("mod.zig");
const rcu = @import("../concurrency/rcu.zig");
const scratch_mod = @import("../mutation/scratch.zig");

pub const RunDesc = struct {
    start: u32,
    count: u32,
};

pub fn runCount(side_adj: types.SideAdj) u16 {
    if (side_adj.block_count == 0) return 0;
    return if (side_adj.group_count == 0) 1 else side_adj.group_count;
}

pub fn runAt(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, run_idx: u16) ?RunDesc {
    if (side_adj.block_count == 0) return null;
    if (side_adj.group_count == 0) {
        if (run_idx != 0) return null;
        return .{ .start = side_adj.first_block, .count = side_adj.block_count };
    }
    if (run_idx >= side_adj.group_count) return null;
    const group_idx = side_adj.first_group + run_idx;
    if (group_idx >= graph.loadGroupCount()) return null;
    const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
    return .{ .start = group.start, .count = group.count };
}

pub fn tailRun(graph: *const graph_core.GraphCore, side_adj: types.SideAdj) ?RunDesc {
    const total_runs = runCount(side_adj);
    if (total_runs == 0) return null;
    return runAt(graph, side_adj, total_runs - 1);
}

pub fn cloneGroupedRuns(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    target_group_count: u16,
    scratch: *scratch_mod.MutationScratch,
) !u32 {
    try adjacency.validateSideAdjLayout(graph, side_adj.*);
    std.debug.assert(side_adj.group_count > 0);
    std.debug.assert(target_group_count > 0);
    std.debug.assert(target_group_count <= constants.MAX_GROUPS_PER_NODE);

    const first_group_idx = try scratch.allocGroupSpan(graph, target_group_count);
    var run_idx: u16 = 0;
    while (run_idx < side_adj.group_count and run_idx < target_group_count) : (run_idx += 1) {
        page_ops.edgeBlockGroupAt(graph, first_group_idx + run_idx).* = page_ops.edgeBlockGroupAtConst(graph, side_adj.first_group + run_idx).*;
    }
    return first_group_idx;
}

pub fn forEachRun(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    context: anytype,
    comptime callback: anytype,
) !void {
    const total_runs = runCount(side_adj);
    if (total_runs == 0) return;

    var run_idx: u16 = 0;
    while (run_idx < total_runs) : (run_idx += 1) {
        const run = runAt(graph, side_adj, run_idx) orelse return error.CorruptGraph;
        try callback(graph, context, run, run_idx + 1 == total_runs);
    }
}

pub const BlockCursor = struct {
    side: types.SideAdj,
    current_block_idx: u32 = 0,
    blocks_remaining: u32 = 0,
    group_idx: u32 = constants.END_OF_CHAIN,
    groups_remaining: u16 = 0,
    contiguous: bool = false,
    done: bool = true,

    pub fn init(side: types.SideAdj) BlockCursor {
        if (side.block_count == 0) {
            return .{ .side = side };
        }

        if (side.group_count == 0) {
            return .{
                .side = side,
                .current_block_idx = side.first_block,
                .blocks_remaining = side.block_count,
                .groups_remaining = 1,
                .contiguous = true,
                .done = false,
            };
        }

        return .{
            .side = side,
            .group_idx = side.first_group,
            .groups_remaining = side.group_count,
            .done = false,
        };
    }

    pub fn next(self: *BlockCursor, graph: *const graph_core.GraphCore) ?u32 {
        if (self.done) return null;

        while (self.blocks_remaining == 0) {
            if (self.contiguous or self.groups_remaining == 0) {
                self.done = true;
                return null;
            }
            if (self.group_idx >= graph.loadGroupCount()) {
                self.done = true;
                return null;
            }

            const group = page_ops.edgeBlockGroupAtConst(graph, self.group_idx);
            self.current_block_idx = group.start;
            self.blocks_remaining = group.count;
            self.group_idx += 1;
            self.groups_remaining -= 1;
        }

        const block_idx = self.current_block_idx;
        self.current_block_idx += 1;
        self.blocks_remaining -= 1;
        return block_idx;
    }
};

pub const SideBuilder = struct {
    run_start_idx: u32 = 0,
    run_block_count: u32 = 0,
    total_blocks: u32 = 0,
    first_block_set: bool = false,
    runs: [constants.MAX_GROUPS_PER_NODE]RunDesc = undefined,
    run_count: u16 = 0,

    pub fn begin(side_adj: *types.SideAdj) SideBuilder {
        side_adj.first_block = 0;
        side_adj.block_count = 0;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return .{};
    }

    pub fn appendBlock(
        self: *SideBuilder,
        side_adj: *types.SideAdj,
        graph: *graph_core.GraphCore,
        block_idx: u32,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        _ = graph;
        _ = scratch;
        if (self.run_block_count > 0 and block_idx == self.run_start_idx + self.run_block_count) {
            self.run_block_count += 1;
        } else {
            if (self.run_block_count > 0) try self.flush(side_adj);
            self.run_start_idx = block_idx;
            self.run_block_count = 1;
        }
    }

    fn flush(self: *SideBuilder, side_adj: *types.SideAdj) !void {
        if (self.run_block_count == 0) return;
        if (!self.first_block_set) {
            side_adj.first_block = self.run_start_idx;
            side_adj.block_count = self.run_block_count;
            self.first_block_set = true;
        } else if (self.run_count == 0) {
            self.runs[0] = .{ .start = side_adj.first_block, .count = side_adj.block_count };
            self.runs[1] = .{ .start = self.run_start_idx, .count = self.run_block_count };
            self.run_count = 2;
        } else {
            if (self.run_count >= constants.MAX_GROUPS_PER_NODE) return error.RepairRequired;
            self.runs[self.run_count] = .{ .start = self.run_start_idx, .count = self.run_block_count };
            self.run_count += 1;
        }
        self.total_blocks += self.run_block_count;
        self.run_block_count = 0;
    }

    pub fn finish(
        self: *SideBuilder,
        side_adj: *types.SideAdj,
        graph: *graph_core.GraphCore,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        if (self.run_block_count > 0) try self.flush(side_adj);
        side_adj.block_count = self.total_blocks;
        if (self.run_count == 0) return;

        if (self.run_count == 1) {
            side_adj.first_block = self.runs[0].start;
            side_adj.group_count = 0;
            side_adj.first_group = 0;
            return;
        }

        const first_group_idx = try scratch.allocGroupSpan(graph, self.run_count);
        side_adj.first_group = first_group_idx;
        side_adj.group_count = self.run_count;
        var run_idx: u16 = 0;
        while (run_idx < self.run_count) : (run_idx += 1) {
            page_ops.edgeBlockGroupAt(graph, first_group_idx + run_idx).* = .{
                .start = self.runs[run_idx].start,
                .count = self.runs[run_idx].count,
            };
        }
    }
};

pub fn collectBlockList(
    graph: *const graph_core.GraphCore,
    published_side_adj: types.SideAdj,
    old_block_idx: ?u32,
    new_block_idx: ?u32,
    append_block_idx: ?u32,
    out: *std.ArrayList(u32),
) !void {
    var cursor = BlockCursor.init(published_side_adj);
    while (cursor.next(graph)) |block_idx| {
        if (old_block_idx != null and block_idx == old_block_idx.?) {
            if (new_block_idx) |replacement_block_idx| try out.append(graph.allocator, replacement_block_idx);
        } else {
            try out.append(graph.allocator, block_idx);
        }
    }
    if (append_block_idx) |tail_block_idx| try out.append(graph.allocator, tail_block_idx);
}

pub fn buildSideFromBlocks(
    side_adj: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *scratch_mod.MutationScratch,
) !void {
    side_adj.first_block = 0;
    side_adj.block_count = 0;
    side_adj.group_count = 0;
    side_adj.first_group = 0;
    if (blocks.len == 0) return;

    var builder = SideBuilder.begin(side_adj);
    for (blocks) |block_idx| {
        try builder.appendBlock(side_adj, graph, block_idx, scratch);
    }
    try builder.finish(side_adj, graph, scratch);
}

pub fn retireSide(
    graph: *graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !void {
    if (side_adj.block_count == 0) return;

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        switch (side) {
            .fwd => try rcu.retireBlockFwd(graph, block_idx),
            .rev => try rcu.retireBlockRev(graph, block_idx),
        }
    }

    if (side_adj.group_count == 0) return;
    rcu.retireGroupSpan(graph, side_adj.first_group, side_adj.group_count);
}

pub fn retireRun(
    graph: *graph_core.GraphCore,
    run: RunDesc,
    comptime side: adjacency.AdjSide,
) !void {
    for (run.start..run.start + run.count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        switch (side) {
            .fwd => try rcu.retireBlockFwd(graph, block_idx),
            .rev => try rcu.retireBlockRev(graph, block_idx),
        }
    }
}
