//! Shared mutation primitives — claim ordering, writer lifecycle, adjacency search,
//! and adjacency rebuild helpers reused by edge and node mutations.

const std = @import("std");
const constants = @import("../constants.zig");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const page_ops = @import("../page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const node_validity = @import("../node_validity.zig");

/// Tracks which adjacency claims were successfully acquired during a mutation,
/// so the deferred release only drops the ones that were actually taken.
pub const ClaimedAdjacencies = struct {
    source_node: *types.NodeBuffer,
    destination_node: *types.NodeBuffer,
    source_fwd_claimed: bool = false,
    source_rev_claimed: bool = false,
    destination_fwd_claimed: bool = false,
    destination_rev_claimed: bool = false,

    pub fn release(self: *ClaimedAdjacencies) void {
        if (self.destination_rev_claimed) self.destination_node.rev_claim.store(0, .release);
        if (self.destination_fwd_claimed) self.destination_node.fwd_claim.store(0, .release);
        if (self.source_rev_claimed) self.source_node.rev_claim.store(0, .release);
        if (self.source_fwd_claimed) self.source_node.fwd_claim.store(0, .release);
    }

    fn claimNodeFwd(self: *ClaimedAdjacencies, node: *types.NodeBuffer) !void {
        if (node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        if (node == self.source_node) self.source_fwd_claimed = true else self.destination_fwd_claimed = true;
    }

    fn claimNodeRev(self: *ClaimedAdjacencies, node: *types.NodeBuffer) !void {
        if (node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        if (node == self.source_node) self.source_rev_claimed = true else self.destination_rev_claimed = true;
    }
};

pub const ClaimedNodeSides = struct {
    node: *types.NodeBuffer,
    fwd_claimed: bool = false,
    rev_claimed: bool = false,

    pub fn release(self: *ClaimedNodeSides) void {
        if (self.rev_claimed) self.node.rev_claim.store(0, .release);
        if (self.fwd_claimed) self.node.fwd_claim.store(0, .release);
    }

    pub fn ensureFwd(self: *ClaimedNodeSides) !void {
        if (self.fwd_claimed) return;
        if (self.node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        self.fwd_claimed = true;
    }

    pub fn ensureRev(self: *ClaimedNodeSides) !void {
        if (self.rev_claimed) return;
        if (self.node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        self.rev_claimed = true;
    }
};

pub const WriterGuard = struct {
    graph: *graph_core.GraphCore,
    active: bool = true,

    pub fn end(self: *WriterGuard) void {
        if (!self.active) return;
        _ = self.graph.active_writers.fetchSub(1, .acq_rel);
        self.active = false;
    }
};

pub const AdjSlot = struct {
    block_idx: u32,
    slot: u7,
};

/// Temporary allocation tracker shared by all mutations.  Tracks
/// forward blocks, reverse blocks and groups, with automatic cleanup.
pub const MutationScratch = struct {
    fwd_blocks: std.ArrayList(u32) = .empty,
    rev_blocks: std.ArrayList(u32) = .empty,
    groups: std.ArrayList(u32) = .empty,
    active: bool = true,

    pub fn allocBlock(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
        const block = try page_ops.allocBlock(graph, side);
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };
        list.append(graph.allocator, block) catch |err| {
            page_ops.freeBlock(graph, block, side);
            return err;
        };
        return block;
    }

    pub fn allocGroup(self: *MutationScratch, graph: *graph_core.GraphCore) !u32 {
        const group = try page_ops.allocGroup(graph);
        self.groups.append(graph.allocator, group) catch |err| {
            page_ops.freeGroup(graph, group);
            return err;
        };
        return group;
    }

    pub fn adoptBlocks(self: *MutationScratch, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide, blocks: []const u32) !void {
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };
        try list.appendSlice(allocator, blocks);
    }

    pub fn disarm(self: *MutationScratch) void {
        self.active = false;
    }

    pub fn cleanup(self: *MutationScratch, graph: *graph_core.GraphCore) void {
        if (!self.active) return;
        for (self.fwd_blocks.items) |b| page_ops.freeBlock(graph, b, .fwd);
        for (self.rev_blocks.items) |b| page_ops.freeBlock(graph, b, .rev);
        for (self.groups.items) |g| page_ops.freeGroup(graph, g);
    }

    pub fn deinit(self: *MutationScratch, allocator: std.mem.Allocator) void {
        self.fwd_blocks.deinit(allocator);
        self.rev_blocks.deinit(allocator);
        self.groups.deinit(allocator);
    }

    pub fn freeGroup(self: *MutationScratch, graph: *graph_core.GraphCore, group: u32) void {
        for (self.groups.items, 0..) |g, i| {
            if (g == group) {
                _ = self.groups.swapRemove(i);
                page_ops.freeGroup(graph, group);
                return;
            }
        }
        page_ops.freeGroup(graph, group);
    }
};

/// Iterates over runs of contiguous blocks described by a `SideAdj`.
/// Abstracts away the `group_count == 0` vs `group_count > 0` shape
/// so consumers only see `(start, count)` windows.
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

/// Iterates over individual block indices described by a `SideAdj`.
/// Abstracts away `group_count == 0` vs grouped traversal.
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

/// Builds a `SideAdj` from a slice of block indices, coalescing
/// contiguous blocks into runs and creating `EdgeBlockGroup` records
/// when the layout is not physically contiguous.
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
        scratch: *MutationScratch,
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
        scratch: *MutationScratch,
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

    pub fn finish(self: *SideBuilder, side: *types.SideAdj, graph: *graph_core.GraphCore, scratch: *MutationScratch) !void {
        if (self.run_count > 0) try self.flush(side, graph, scratch);
        side.block_count = self.total_blocks;
    }
};

/// Builds a `SideAdj` from a slice of block indices using `SideBuilder`.
pub fn buildSideFromBlocks(
    side: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *MutationScratch,
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

/// Retires every block and group in one side of a `NodeAdj`,
/// using the side-uniform retirement helpers.
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

/// Publishes both forward and reverse sides from a composed `NodeAdj`.
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
    _ = publishStagedBoth(node, meta, adj.flags, fwd_degree, rev_degree);
}

/// Publishes only the reverse side from a composed `NodeAdj`.
pub fn publishRevAdj(
    node: *types.NodeBuffer,
    adj: types.NodeAdj,
    new_rev_degree: u22,
) void {
    const meta = node.loadPublishedMeta();
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = publishStagedRev(node, meta, adj.flags.needs_repair_rev, new_rev_degree);
}

pub fn beginWriter(graph: *graph_core.GraphCore) WriterGuard {
    const previous_writers = graph.active_writers.fetchAdd(1, .acq_rel);
    if (previous_writers > 0) graph.debug_retired_enabled.store(false, .release);
    return .{ .graph = graph };
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

pub fn tryClaimAdjacencies(source_node: *types.NodeBuffer, destination_node: *types.NodeBuffer, source_index: u32, destination_index: u32) !ClaimedAdjacencies {
    var claims = ClaimedAdjacencies{
        .source_node = source_node,
        .destination_node = destination_node,
    };
    errdefer claims.release();

    // Forward and reverse adjacency are published independently via per-side RCU.
    // `addEdge(from, to)` touches only `forward(from)` and `reverse(to)`, so we
    // claim exactly those two logical sides.  Self-edges claim both sides of the
    // same node.
    if (source_index == destination_index) {
        try claims.claimNodeFwd(source_node);
        try claims.claimNodeRev(source_node);
    } else {
        try claims.claimNodeFwd(source_node);
        try claims.claimNodeRev(destination_node);
    }

    return claims;
}

pub fn tryClaimNodeSides(node: *types.NodeBuffer, want_fwd: bool, want_rev: bool) !ClaimedNodeSides {
    var claims = ClaimedNodeSides{ .node = node };
    errdefer claims.release();
    if (want_fwd) try claims.ensureFwd();
    if (want_rev) try claims.ensureRev();
    return claims;
}

pub fn publishStagedFwd(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishFwd(expected, needs_repair_fwd, new_degree_fwd);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedRev(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, needs_repair_rev: bool, new_degree_rev: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishRev(expected, needs_repair_rev, new_degree_rev);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedBoth(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u22, rev_degree: u22) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishBoth(expected, flags, fwd_degree, rev_degree);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

/// Searches a contiguous or grouped adjacency chain for a single target value.
///
/// Returns the block index and slot where `target` was found, or null.
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
