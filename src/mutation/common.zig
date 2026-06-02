//! Shared mutation primitives — claim ordering, writer lifecycle, adjacency search,
//! and adjacency rebuild helpers reused by edge and node mutations.

const std = @import("std");
const constants = @import("../constants.zig");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const page_ops = @import("../page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");

/// Increment the degree cache.  Caller must hold the writer claim.
pub fn incrementDegree(deg: *u16) void {
    if (deg.* < constants.DEGREE_OVERFLOW - 1) deg.* += 1 else deg.* = constants.DEGREE_OVERFLOW;
}

/// Decrement the degree cache.  Caller must hold the writer claim.
/// If the counter does not hold a valid cached value it is forced to
/// `DEGREE_OVERFLOW` so callers fall back to the O(B) scan.
pub fn decrementDegree(deg: *u16) void {
    if (deg.* > 0 and deg.* < constants.DEGREE_OVERFLOW) deg.* -= 1 else deg.* = constants.DEGREE_OVERFLOW;
}

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

pub const PrePublishAllocations = struct {
    forward_blocks: std.ArrayList(u32) = .empty,
    reverse_blocks: std.ArrayList(u32) = .empty,
    groups: std.ArrayList(u32) = .empty,
    active: bool = true,

    pub fn allocBlock(self: *PrePublishAllocations, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
        const block = try page_ops.allocBlock(graph, side);
        const list = switch (side) {
            .fwd => &self.forward_blocks,
            .rev => &self.reverse_blocks,
        };
        list.append(graph.allocator, block) catch |err| {
            page_ops.freeBlock(graph, block, side);
            return err;
        };
        return block;
    }

    pub fn allocGroup(self: *PrePublishAllocations, graph: *graph_core.GraphCore) !u32 {
        const group = try page_ops.allocGroup(graph);
        self.groups.append(graph.allocator, group) catch |err| {
            page_ops.freeGroup(graph, group);
            return err;
        };
        return group;
    }

    pub fn adoptBlocks(self: *PrePublishAllocations, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide, blocks: []const u32) !void {
        const list = switch (side) {
            .fwd => &self.forward_blocks,
            .rev => &self.reverse_blocks,
        };
        try list.appendSlice(allocator, blocks);
    }

    pub fn disarm(self: *PrePublishAllocations) void {
        self.active = false;
    }

    pub fn cleanup(self: *PrePublishAllocations, graph: *graph_core.GraphCore) void {
        if (!self.active) return;
        for (self.forward_blocks.items) |block| page_ops.freeBlock(graph, block, .fwd);
        for (self.reverse_blocks.items) |block| page_ops.freeBlock(graph, block, .rev);
        for (self.groups.items) |group| page_ops.freeGroup(graph, group);
    }

    pub fn deinit(self: *PrePublishAllocations, allocator: std.mem.Allocator) void {
        self.forward_blocks.deinit(allocator);
        self.reverse_blocks.deinit(allocator);
        self.groups.deinit(allocator);
    }
};

pub const AdjSlot = struct {
    block_idx: u32,
    slot: u7,
};

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

pub fn publishStagedFwd(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        var merged_flags = expected.flags();
        merged_flags.needs_repair_fwd = flags.needs_repair_fwd;
        merged_flags.removed = flags.removed;
        const desired = types.NodeBuffer.desiredMetaForPublishFwd(expected, merged_flags);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedRev(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        var merged_flags = expected.flags();
        merged_flags.needs_repair_rev = flags.needs_repair_rev;
        merged_flags.removed = flags.removed;
        const desired = types.NodeBuffer.desiredMetaForPublishRev(expected, merged_flags);
        const actual = node.cmpxchgPublishedMeta(expected, desired) orelse return desired;
        expected = actual;
    }
}

pub fn publishStagedBoth(node: *types.NodeBuffer, expected_meta: types.PublishedMeta, flags: types.NodeFlags) types.PublishedMeta {
    var expected = expected_meta;
    while (true) {
        const desired = types.NodeBuffer.desiredMetaForPublishBoth(expected, flags);
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
    while (group_idx != constants.END_OF_CHAIN) {
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

/// Rebuilds `staging_adj` by walking the published adjacency and replacing
/// `old_block` with `new_block`. Detects contiguous runs to minimise group
/// allocations and chain links — O(N) instead of O(N²).
pub fn rebuildAdjWithReplace(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    old_block: u32,
    new_block: u32,
    comptime side: adjacency.AdjSide,
) !void {
    switch (side) {
        .fwd => {
            staging_adj.first_block_fwd = 0;
            staging_adj.block_count_fwd = 0;
            staging_adj.group_count_fwd = 0;
            staging_adj.first_group_fwd = 0;
        },
        .rev => {
            staging_adj.first_block_rev = 0;
            staging_adj.block_count_rev = 0;
            staging_adj.group_count_rev = 0;
            staging_adj.first_group_rev = 0;
        },
    }
    if (block_count == 0) return;

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set: bool = false;
    var tail_group: ?u32 = null;

    const EmitCtx = struct {
        fn flush(
            adj: *types.NodeAdj,
            graph_ptr: *graph_core.GraphCore,
            comptime dir: adjacency.AdjSide,
            run_start_ptr: *u32,
            run_count_ptr: *u16,
            total_blocks_ptr: *u16,
            first_block_set_ptr: *bool,
            tail_group_ptr: *?u32,
        ) !void {
            if (run_count_ptr.* == 0) return;
            if (!first_block_set_ptr.*) {
                switch (dir) {
                    .fwd => {
                        adj.first_block_fwd = run_start_ptr.*;
                        adj.block_count_fwd = run_count_ptr.*;
                    },
                    .rev => {
                        adj.first_block_rev = run_start_ptr.*;
                        adj.block_count_rev = run_count_ptr.*;
                    },
                }
                first_block_set_ptr.* = true;
            } else if (tail_group_ptr.* == null and (switch (dir) {
                .fwd => adj.group_count_fwd,
                .rev => adj.group_count_rev,
            }) == 0) {
                const prefix_group = try page_ops.allocGroup(graph_ptr);
                const group = try page_ops.allocGroup(graph_ptr);
                const first_start: u32 = switch (dir) {
                    .fwd => adj.first_block_fwd,
                    .rev => adj.first_block_rev,
                };
                const first_cnt: u16 = switch (dir) {
                    .fwd => adj.block_count_fwd,
                    .rev => adj.block_count_rev,
                };
                page_ops.groupAt(graph_ptr, prefix_group).* = .{ .start = first_start, .count = first_cnt, .next = group };
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                switch (dir) {
                    .fwd => {
                        adj.first_group_fwd = prefix_group;
                        adj.group_count_fwd = 2;
                    },
                    .rev => {
                        adj.first_group_rev = prefix_group;
                        adj.group_count_rev = 2;
                    },
                }
                tail_group_ptr.* = group;
            } else {
                const group = try page_ops.allocGroup(graph_ptr);
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                page_ops.groupAt(graph_ptr, tail_group_ptr.*.?).next = group;
                tail_group_ptr.* = group;
                switch (dir) {
                    .fwd => adj.group_count_fwd += 1,
                    .rev => adj.group_count_rev += 1,
                }
            }
            total_blocks_ptr.* += run_count_ptr.*;
            run_count_ptr.* = 0;
        }
    };

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            if (block_idx == old_block) {
                if (@popCount(page_ops.edgeBlockAtConst(graph, new_block, side).mask) == 0) continue;
            }
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                run_start = idx;
                run_count = 1;
            }
        }
        try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
        switch (side) {
            .fwd => staging_adj.block_count_fwd = total_blocks,
            .rev => staging_adj.block_count_rev = total_blocks,
        }
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            if (block_idx == old_block) {
                if (@popCount(page_ops.edgeBlockAtConst(graph, new_block, side).mask) == 0) continue;
            }
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                run_start = idx;
                run_count = 1;
            }
        }
        group_idx = group.next;
    }
    try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
    switch (side) {
        .fwd => staging_adj.block_count_fwd = total_blocks,
        .rev => staging_adj.block_count_rev = total_blocks,
    }
}

/// SideAdj version of rebuildAdjWithReplace for per-side publication model.
pub fn rebuildAdjWithReplaceSide(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    old_block: u32,
    new_block: u32,
    comptime side: adjacency.AdjSide,
    allocs: ?*PrePublishAllocations,
) !void {
    staging_side.first_block = 0;
    staging_side.block_count = 0;
    staging_side.group_count = 0;
    staging_side.first_group = 0;
    if (block_count == 0) return;

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set: bool = false;
    var tail_group: ?u32 = null;

    const EmitCtx = struct {
        fn flush(
            adj: *types.SideAdj,
            graph_ptr: *graph_core.GraphCore,
            run_start_ptr: *u32,
            run_count_ptr: *u16,
            total_blocks_ptr: *u16,
            first_block_set_ptr: *bool,
            tail_group_ptr: *?u32,
            allocs_optional: ?*PrePublishAllocations,
        ) !void {
            if (run_count_ptr.* == 0) return;
            if (!first_block_set_ptr.*) {
                adj.first_block = run_start_ptr.*;
                adj.block_count = run_count_ptr.*;
                first_block_set_ptr.* = true;
            } else if (tail_group_ptr.* == null and adj.group_count == 0) {
                const prefix_group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
                const group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
                page_ops.groupAt(graph_ptr, prefix_group).* = .{ .start = adj.first_block, .count = adj.block_count, .next = group };
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                adj.first_group = prefix_group;
                adj.group_count = 2;
                tail_group_ptr.* = group;
            } else {
                const group = if (allocs_optional) |a| try a.allocGroup(graph_ptr) else try page_ops.allocGroup(graph_ptr);
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                page_ops.groupAt(graph_ptr, tail_group_ptr.*.?).next = group;
                tail_group_ptr.* = group;
                adj.group_count += 1;
            }
            total_blocks_ptr.* += run_count_ptr.*;
            run_count_ptr.* = 0;
        }
    };

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            if (block_idx == old_block) {
                if (@popCount(page_ops.edgeBlockAtConst(graph, new_block, side).mask) == 0) continue;
            }
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_side, graph, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
                run_start = idx;
                run_count = 1;
            }
        }
        try EmitCtx.flush(staging_side, graph, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
        staging_side.block_count = total_blocks;
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            if (block_idx == old_block) {
                if (@popCount(page_ops.edgeBlockAtConst(graph, new_block, side).mask) == 0) continue;
            }
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_side, graph, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
                run_start = idx;
                run_count = 1;
            }
        }
        group_idx = group.next;
    }
    try EmitCtx.flush(staging_side, graph, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group, allocs);
    staging_side.block_count = total_blocks;
}
