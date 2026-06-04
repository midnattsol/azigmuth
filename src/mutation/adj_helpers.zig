const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const scratch_mod = @import("scratch.zig");
const claims_mod = @import("claims.zig");

pub const AdjSlot = struct {
    block_idx: u32,
    slot: u7,
};

pub const Run = struct { start: u32, count: u16 };

pub const RunCursor = struct {
    side: types.SideAdj,
    group_index: u32,
    groups_remaining: u16,
    done: bool,

    pub fn init(side: types.SideAdj) RunCursor {
        if (side.block_count == 0) {
            return .{
                .side = side,
                .group_index = 0,
                .groups_remaining = 0,
                .done = true,
            };
        }
        if (side.group_count == 0) {
            return .{
                .side = side,
                .group_index = side.first_block,
                .groups_remaining = 1,
                .done = false,
            };
        }
        return .{
            .side = side,
            .group_index = side.first_group,
            .groups_remaining = side.group_count,
            .done = false,
        };
    }

    pub fn next(self: *RunCursor, graph: *const graph_core.GraphCore) ?Run {
        if (self.done) return null;
        if (self.groups_remaining == 0) {
            self.done = true;
            return null;
        }
        if (self.side.group_count == 0) {
            self.done = true;
            return Run{ .start = self.side.first_block, .count = self.side.block_count };
        }
        self.groups_remaining -= 1;
        if (self.group_index >= graph.group_count or self.group_index == constants.END_OF_CHAIN) {
            self.done = true;
            return null;
        }
        const group = page_ops.groupAtConst(graph, self.group_index);
        const result = Run{ .start = group.start, .count = group.count };
        self.group_index = group.next;
        return result;
    }
};

pub const BlockCursor = struct {
    side: types.SideAdj,
    run_cursor: RunCursor,
    current_run: ?Run = null,
    offset: u32 = 0,

    pub fn init(side: types.SideAdj) BlockCursor {
        return .{ .side = side, .run_cursor = RunCursor.init(side) };
    }

    pub fn next(self: *BlockCursor, graph: *const graph_core.GraphCore) ?u32 {
        while (true) {
            if (self.current_run != null and self.offset < self.current_run.?.count) {
                const block_idx = self.current_run.?.start + self.offset;
                self.offset += 1;
                return block_idx;
            }
            self.current_run = self.run_cursor.next(graph) orelse return null;
            self.offset = 0;
        }
    }
};

pub const SideBuilder = struct {
    side: types.SideAdj,
    run_start: u32 = 0,
    run_count: u16 = 0,
    total_blocks: u16 = 0,
    first_block_set: bool = false,
    tail_group: ?u32 = null,

    pub fn begin(side: *types.SideAdj) SideBuilder {
        side.first_block = 0;
        side.block_count = 0;
        side.group_count = 0;
        side.first_group = 0;
        return .{ .side = undefined };
    }

    pub fn appendBlock(
        self: *SideBuilder,
        side: *types.SideAdj,
        graph: *graph_core.GraphCore,
        block_idx: u32,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        if (self.run_count > 0 and block_idx == self.run_start + self.run_count) {
            self.run_count += 1;
        } else {
            if (self.run_count > 0) try self.flush(side, graph, scratch);
            self.run_start = block_idx;
            self.run_count = 1;
        }
    }

    fn flush(
        self: *SideBuilder,
        side: *types.SideAdj,
        graph: *graph_core.GraphCore,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        if (self.run_count == 0) return;
        if (!self.first_block_set) {
            side.first_block = self.run_start;
            side.block_count = self.run_count;
            self.first_block_set = true;
        } else if (self.tail_group == null and side.group_count == 0) {
            const prefix_group = try scratch.allocGroup(graph);
            const group = try scratch.allocGroup(graph);
            page_ops.groupAt(graph, prefix_group).* = .{
                .start = side.first_block, .count = side.block_count, .next = group,
            };
            page_ops.groupAt(graph, group).* = .{
                .start = self.run_start, .count = self.run_count, .next = constants.END_OF_CHAIN,
            };
            side.first_group = prefix_group;
            side.group_count = 2;
            self.tail_group = group;
        } else {
            if (side.group_count >= constants.MAX_GROUPS_PER_NODE) return error.RepairRequired;
            const group = try scratch.allocGroup(graph);
            page_ops.groupAt(graph, group).* = .{
                .start = self.run_start, .count = self.run_count, .next = constants.END_OF_CHAIN,
            };
            page_ops.groupAt(graph, self.tail_group.?).next = group;
            self.tail_group = group;
            side.group_count += 1;
        }
        self.total_blocks += self.run_count;
        self.run_count = 0;
    }

    pub fn finish(self: *SideBuilder, side: *types.SideAdj, graph: *graph_core.GraphCore, scratch: *scratch_mod.MutationScratch) !void {
        if (self.run_count > 0) try self.flush(side, graph, scratch);
        side.block_count = self.total_blocks;
    }
};

pub fn collectBlockList(
    graph: *const graph_core.GraphCore,
    published_side: types.SideAdj,
    old_block: ?u32,
    new_block: ?u32,
    append_block: ?u32,
    out: *std.ArrayList(u32),
) !void {
    var cursor = BlockCursor.init(published_side);
    while (cursor.next(graph)) |block_idx| {
        if (old_block != null and block_idx == old_block.?) {
            if (new_block) |nb| try out.append(graph.allocator, nb);
        } else {
            try out.append(graph.allocator, block_idx);
        }
    }
    if (append_block) |ab| try out.append(graph.allocator, ab);
}

pub fn buildSideFromBlocks(
    side: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *scratch_mod.MutationScratch,
) !void {
    side.first_block = 0;
    side.block_count = 0;
    side.group_count = 0;
    side.first_group = 0;
    if (blocks.len == 0) return;

    var builder = SideBuilder{ .side = undefined };
    for (blocks) |block_idx| {
        try builder.appendBlock(side, graph, block_idx, scratch);
    }
    try builder.finish(side, graph, scratch);
}

pub fn retireSide(
    graph: *graph_core.GraphCore,
    adj_before: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const first_block: u32 = if (side == .fwd) adj_before.first_block_fwd else adj_before.first_block_rev;
    const block_count: u16 = if (side == .fwd) adj_before.block_count_fwd else adj_before.block_count_rev;
    const group_count: u16 = if (side == .fwd) adj_before.group_count_fwd else adj_before.group_count_rev;
    const first_group: u32 = if (side == .fwd) adj_before.first_group_fwd else adj_before.first_group_rev;

    if (block_count == 0) return;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(graph, @intCast(block_idx)),
                .rev => try rcu.retireBlockRev(graph, @intCast(block_idx)),
            }
        }
        return;
    }

    var group_idx = first_group;
    var visited: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (visited >= group_count or visited >= graph.group_count) return error.CorruptGraph;
        visited += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(graph, @intCast(block_idx)),
                .rev => try rcu.retireBlockRev(graph, @intCast(block_idx)),
            }
        }
        const old_group = group_idx;
        group_idx = group.next;
        rcu.retireGroup(graph, old_group);
    }
}

pub fn publishBothAdj(
    node: *types.NodeBuffer,
    adj: types.NodeAdj,
    fwd_degree: u22,
    rev_degree: u22,
) void {
    const meta = node.loadPublishedMeta();
    node.stagingFwd(meta).* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = claims_mod.publishStagedBoth(node, meta, adj.flags, fwd_degree, rev_degree);
}

pub fn publishRevAdj(
    node: *types.NodeBuffer,
    adj: types.NodeAdj,
    new_rev_degree: u22,
) void {
    const meta = node.loadPublishedMeta();
    const rev_delta: i23 = @intCast(@as(i64, @intCast(new_rev_degree)) - @as(i64, @intCast(meta.degree_rev)));
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = claims_mod.publishStagedRev(node, meta, adj.flags.needs_repair_rev, rev_delta);
}

pub fn retireGroupChain(graph: *graph_core.GraphCore, first_group: u32, group_count: u16) void {
    var group_index = first_group;
    var remaining = group_count;
    while (remaining > 0 and group_index != constants.END_OF_CHAIN) : (remaining -= 1) {
        const next_group = page_ops.groupAtConst(graph, group_index).next;
        rcu.retireGroup(graph, group_index);
        group_index = next_group;
    }
}

pub fn findSlotInAdj(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
) ?AdjSlot {
    if (block_count == 0) return null;

    if (group_count == 0) {
        return findSlotInBlockRun(graph, first_block, block_count, target, side);
    }

    var group_idx = first_group;
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) return null;
        const group = page_ops.groupAtConst(graph, group_idx);
        if (findSlotInBlockRun(graph, group.start, group.count, target, side)) |slot| return slot;
        group_idx = group.next;
    }
    return null;
}

fn findSlotInBlockRunLinear(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: adjacency.AdjSide,
) ?AdjSlot {
    for (start..start + count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        const slot = switch (side) {
            .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, target),
            .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, target),
        } orelse continue;
        return .{ .block_idx = block_idx, .slot = slot };
    }
    return null;
}

fn findSlotInBlockRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: adjacency.AdjSide,
) ?AdjSlot {
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block_idx = start + mid;
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        const live = @popCount(block.mask);
        if (live == 0) break;
        const first_edge = switch (side) {
            .fwd => block.edges[0].destination,
            .rev => block.sources[0],
        };
        const last_edge = switch (side) {
            .fwd => block.edges[live - 1].destination,
            .rev => block.sources[live - 1],
        };
        if (target < first_edge) {
            high = mid;
        } else if (target > last_edge) {
            low = mid + 1;
        } else {
            const slot = switch (side) {
                .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, target),
                .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, target),
            } orelse break;
            return .{ .block_idx = block_idx, .slot = slot };
        }
    }
    return findSlotInBlockRunLinear(graph, start, count, target, side);
}
