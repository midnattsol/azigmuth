const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");
const scratch_mod = @import("mutation/scratch.zig");
const claims_mod = @import("mutation/claims.zig");

pub const AdjSlot = struct {
    block_idx: u32,
    slot: u7,
};

pub const BlockCursor = struct {
    side: types.SideAdj,
    current_block_idx: u32 = 0,
    blocks_remaining: u16 = 0,
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
            if (self.group_idx >= graph.group_count or self.group_idx == constants.END_OF_CHAIN) {
                self.done = true;
                return null;
            }

            const group = page_ops.groupAtConst(graph, self.group_idx);
            self.current_block_idx = group.start;
            self.blocks_remaining = group.count;
            self.group_idx = group.next;
            self.groups_remaining -= 1;
        }

        const block_idx = self.current_block_idx;
        self.current_block_idx += 1;
        self.blocks_remaining -= 1;
        return block_idx;
    }
};

pub const sideAdjOfNode = adjacency.sideAdjOfNode;

pub fn writeSide(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide, side_view: types.SideAdj) void {
    switch (side) {
        .fwd => {
            node_adj.first_block_fwd = side_view.first_block;
            node_adj.block_count_fwd = side_view.block_count;
            node_adj.group_count_fwd = side_view.group_count;
            node_adj.first_group_fwd = side_view.first_group;
        },
        .rev => {
            node_adj.first_block_rev = side_view.first_block;
            node_adj.block_count_rev = side_view.block_count;
            node_adj.group_count_rev = side_view.group_count;
            node_adj.first_group_rev = side_view.first_group;
        },
    }
}

pub fn nodeAdjForSide(side_view: types.SideAdj, flags: types.NodeFlags, comptime side: adjacency.AdjSide) types.NodeAdj {
    var node_adj = std.mem.zeroes(types.NodeAdj);
    node_adj.flags = flags;
    writeSide(&node_adj, side, side_view);
    return node_adj;
}

pub fn forEachBlockInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        try callback(graph, context, block_idx);
    }
}

pub fn forEachSlotInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            try callback(graph, context, block_idx, @as(u7, @intCast(slot)));
        }
    }
}

fn countLiveSlotsInBlock(
    graph: *const graph_core.GraphCore,
    total: *usize,
    block_idx: u32,
    comptime side: adjacency.AdjSide,
) !void {
    total.* += @popCount(page_ops.edgeBlockAtConst(graph, block_idx, side).mask);
}

pub fn countLiveInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !usize {
    var total: usize = 0;
    try forEachBlockInSide(graph, side_adj, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *usize,
            block_idx: u32,
        ) !void {
            try countLiveSlotsInBlock(inner_graph, inner_total, block_idx, side);
        }
    }.callback);
    return total;
}

pub const SideBuilder = struct {
    run_start_idx: u32 = 0,
    run_block_count: u16 = 0,
    total_blocks: u16 = 0,
    first_block_set: bool = false,
    tail_group_idx: ?u32 = null,

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
        if (self.run_block_count > 0 and block_idx == self.run_start_idx + self.run_block_count) {
            self.run_block_count += 1;
        } else {
            if (self.run_block_count > 0) try self.flush(side_adj, graph, scratch);
            self.run_start_idx = block_idx;
            self.run_block_count = 1;
        }
    }

    fn flush(
        self: *SideBuilder,
        side_adj: *types.SideAdj,
        graph: *graph_core.GraphCore,
        scratch: *scratch_mod.MutationScratch,
    ) !void {
        if (self.run_block_count == 0) return;
        if (!self.first_block_set) {
            side_adj.first_block = self.run_start_idx;
            side_adj.block_count = self.run_block_count;
            self.first_block_set = true;
        } else if (self.tail_group_idx == null and side_adj.group_count == 0) {
            const prefix_group_idx = try scratch.allocGroup(graph);
            const group_idx = try scratch.allocGroup(graph);
            page_ops.groupAt(graph, prefix_group_idx).* = .{
                .start = side_adj.first_block,
                .count = side_adj.block_count,
                .next = group_idx,
            };
            page_ops.groupAt(graph, group_idx).* = .{
                .start = self.run_start_idx,
                .count = self.run_block_count,
                .next = constants.END_OF_CHAIN,
            };
            side_adj.first_group = prefix_group_idx;
            side_adj.group_count = 2;
            self.tail_group_idx = group_idx;
        } else {
            if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return error.RepairRequired;
            const group_idx = try scratch.allocGroup(graph);
            page_ops.groupAt(graph, group_idx).* = .{
                .start = self.run_start_idx,
                .count = self.run_block_count,
                .next = constants.END_OF_CHAIN,
            };
            page_ops.groupAt(graph, self.tail_group_idx.?).next = group_idx;
            self.tail_group_idx = group_idx;
            side_adj.group_count += 1;
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
        if (self.run_block_count > 0) try self.flush(side_adj, graph, scratch);
        side_adj.block_count = self.total_blocks;
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
    try adjacency.validateSideAdjLayout(graph, published_side_adj);
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
    adj_before: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const side_adj = sideAdjOfNode(adj_before, side);
    if (side_adj.block_count == 0) return;

    try forEachBlockInSide(graph, side_adj, side, undefined, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            _: void,
            block_idx: u32,
        ) !void {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(@constCast(inner_graph), block_idx),
                .rev => try rcu.retireBlockRev(@constCast(inner_graph), block_idx),
            }
        }
    }.callback);

    if (side_adj.group_count == 0) return;

    var group_idx = side_adj.first_group;
    var remaining = side_adj.group_count;
    while (remaining > 0 and group_idx != constants.END_OF_CHAIN) : (remaining -= 1) {
        const next_group_idx = page_ops.groupAtConst(graph, group_idx).next;
        rcu.retireGroup(graph, group_idx);
        group_idx = next_group_idx;
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

pub fn retireGroupChain(graph: *graph_core.GraphCore, first_group_idx: u32, group_count: u16) void {
    var group_idx = first_group_idx;
    var remaining = group_count;
    while (remaining > 0 and group_idx != constants.END_OF_CHAIN) : (remaining -= 1) {
        const next_group_idx = page_ops.groupAtConst(graph, group_idx).next;
        rcu.retireGroup(graph, group_idx);
        group_idx = next_group_idx;
    }
}

/// Searches forward adjacency for a specific (destination, edge_id) pair.
pub fn findSlotInAdjById(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u16,
    group_count: u16,
    first_group_idx: u32,
    destination_idx: u32,
    edge_id: u32,
) ?AdjSlot {
    if (!graph.multigraph_enabled) return null;
    if (block_count == 0) return null;

    adjacency.validateSideAdjLayoutForSide(graph, .{
        .first_block = first_block_idx,
        .block_count = block_count,
        .group_count = group_count,
        .first_group = first_group_idx,
    }, .fwd) catch return null;

    if (group_count == 0) {
        const slot = adjacency.findForwardSlotByIdInRun(graph, first_block_idx, block_count, destination_idx, edge_id) orelse return null;
        return .{ .block_idx = slot.block_idx, .slot = slot.slot };
    }

    var group_idx = first_group_idx;
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_idx);
        if (adjacency.findForwardSlotByIdInRun(graph, group.start, group.count, destination_idx, edge_id)) |slot| {
            return .{ .block_idx = slot.block_idx, .slot = slot.slot };
        }
        group_idx = group.next;
    }
    return null;
}

pub fn findSlotInAdj(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u16,
    group_count: u16,
    first_group_idx: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
) ?AdjSlot {
    if (block_count == 0) return null;

    if (group_count == 0) {
        return findSlotInBlockRun(graph, first_block_idx, block_count, target, side);
    }

    var group_idx = first_group_idx;
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
        const first_key = switch (side) {
            .fwd => block.edges[0].destination,
            .rev => block.sources[0],
        };
        const last_key = switch (side) {
            .fwd => block.edges[live - 1].destination,
            .rev => block.sources[live - 1],
        };
        if (target < first_key) {
            high = mid;
        } else if (target > last_key) {
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
