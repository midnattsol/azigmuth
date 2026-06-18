const std = @import("std");
const constants = @import("../../../../core/constants.zig");
const adjacency = @import("../../../../adjacency/mod.zig");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const common = @import("../../../common.zig");
const local_repair = @import("../../../local_repair.zig");

pub const ForwardRemovalResult = struct {
    new_side: types.SideAdj,
    removed: u32,
};

pub fn buildSideFromBlockList(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: []const u32,
) !types.SideAdj {
    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list, scratch);
    return new_side;
}

/// Returns whether the candidate block list would publish a non-tail block
/// below the hard occupancy bound (constants.MIN_OCCUPANCY). Resolved by the synchronous
/// in-call dense repack.
pub fn blockListNeedsRepack(
    graph: *const graph_core.GraphCore,
    block_list: []const u32,
    comptime side: adjacency.AdjSide,
) bool {
    if (block_list.len <= 1) return false;
    for (block_list[0 .. block_list.len - 1]) |block_idx| {
        const alive = page_ops.blockAliveCount(graph, block_idx, side);
        if (alive < constants.MIN_OCCUPANCY) return true;
    }
    return false;
}

fn blockListRunCount(block_list: []const u32) u16 {
    if (block_list.len == 0) return 0;
    var segment_count: u16 = 1;
    for (block_list[0 .. block_list.len - 1], block_list[1..]) |current, next| {
        if (next != current + 1) segment_count += 1;
    }
    return segment_count;
}

/// Copies the listed blocks `[merge_start, merge_start + merge_len)` into a
/// fresh contiguous span, disposing the replaced blocks (scratch-tracked →
/// free stack; published → retire after publish) and rewriting the list.
fn mergeWindowIntoFreshSpan(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    merge_start: usize,
    merge_len: usize,
    comptime side: adjacency.AdjSide,
) !void {
    const first_new = try scratch.allocFreshBlockSpanRaw(graph, side, @intCast(merge_len));
    for (0..merge_len) |offset| {
        const old_block = block_list.items[merge_start + offset];
        const new_block = first_new + @as(u32, @intCast(offset));
        local_repair.copyBlock(graph, old_block, new_block, side);
        if (scratch.isTrackedBlock(side, old_block)) {
            scratch.freeTrackedBlock(graph, side, old_block);
        } else {
            try scratch.markRetireBlock(graph.allocator, side, old_block);
        }
        block_list.items[merge_start + offset] = new_block;
    }
}

/// Resolves a segment-bound overflow (more than constants.MAX_SEGMENTS_PER_NODE segments) with block-level copies
/// only — no per-entry re-sort. A lightly fragmented list (the scattered
/// single-removal case: one extra segment) merges just the cheapest adjacent segment
/// pair; a heavily fragmented one (e.g. a repair rebuild fed from a scattered
/// free stack) is copied wholesale into one contiguous span, which is O(B)
/// and strictly cheaper than pairwise merging at that point.
pub fn coalesceRunsByBlockCopy(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    comptime side: adjacency.AdjSide,
) !void {
    if (blockListRunCount(block_list.items) > constants.MAX_SEGMENTS_PER_NODE * 2) {
        try mergeWindowIntoFreshSpan(graph, scratch, block_list, 0, block_list.items.len, side);
        return;
    }

    while (blockListRunCount(block_list.items) > constants.MAX_SEGMENTS_PER_NODE) {
        // Single pass: locate the adjacent segment pair with the fewest blocks.
        var best_start: usize = 0;
        var best_len: usize = std.math.maxInt(usize);
        var previous_start: usize = 0;
        var previous_len: usize = 0;
        var pos: usize = 0;
        while (pos < block_list.items.len) {
            const start = pos;
            while (pos + 1 < block_list.items.len and block_list.items[pos + 1] == block_list.items[pos] + 1) pos += 1;
            pos += 1;
            const current_len = pos - start;
            if (previous_len != 0) {
                const total = previous_len + current_len;
                if (total < best_len) {
                    best_len = total;
                    best_start = previous_start;
                }
            }
            previous_start = start;
            previous_len = current_len;
        }

        try mergeWindowIntoFreshSpan(graph, scratch, block_list, best_start, best_len, side);
    }
}

const RepackEntry = struct {
    key: u32,
    relation: u16 = 0,
    flags: types.EdgeFlags = .{},
    edge_id: u32 = 0,
    prop_row: u32 = 0,
};

fn repackEntryLessThan(_: void, lhs: RepackEntry, rhs: RepackEntry) bool {
    if (lhs.key != rhs.key) return lhs.key < rhs.key;
    return lhs.edge_id < rhs.edge_id;
}

/// Synchronous in-call repair: repacks the candidate
/// block list into a fresh contiguous dense span so that no non-tail block is
/// published below the hard occupancy bound. Superseded shared blocks are
/// marked for retirement; superseded fresh blocks return to the free stack.
pub fn repackBlockListDense(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    comptime side: adjacency.AdjSide,
) !void {
    var total_alive: usize = 0;
    for (block_list.items) |block_idx| {
        total_alive += page_ops.blockAliveCount(graph, block_idx, side);
    }
    if (total_alive == 0) {
        block_list.clearRetainingCapacity();
        return;
    }

    const entries = try graph.allocator.alloc(RepackEntry, total_alive);
    defer graph.allocator.free(entries);

    var entry_idx: usize = 0;
    for (block_list.items) |block_idx| {
        const alive = page_ops.blockAliveCount(graph, block_idx, side);
        for (0..alive) |slot| {
            entries[entry_idx] = switch (side) {
                .fwd => blk: {
                    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
                    break :blk .{
                        .key = block.destinations[slot],
                        .relation = block.relations[slot],
                        .flags = @bitCast(block.flags[slot]),
                        .edge_id = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).ids[slot] else 0,
                        .prop_row = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAtConst(graph, block_idx).rows[slot] else 0,
                    };
                },
                .rev => .{ .key = page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot] },
            };
            entry_idx += 1;
        }
    }

    std.sort.pdq(RepackEntry, entries, {}, repackEntryLessThan);

    const span_count: u32 = @intCast((total_alive + constants.EDGES_PER_BLOCK - 1) / constants.EDGES_PER_BLOCK);
    const first_block_idx = try scratch.allocFreshBlockSpanRaw(graph, side, span_count);

    var remaining = entries;
    var emit_block_idx = first_block_idx;
    while (remaining.len > 0) : (emit_block_idx += 1) {
        const take = @min(remaining.len, constants.EDGES_PER_BLOCK);
        switch (side) {
            .fwd => {
                const block = page_ops.edgeBlockAt(graph, emit_block_idx, .fwd);
                const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, emit_block_idx) else undefined;
                const prop_block = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, emit_block_idx) else undefined;
                for (remaining[0..take], 0..) |entry, slot| {
                    block.destinations[slot] = entry.key;
                    block.relations[slot] = entry.relation;
                    block.flags[slot] = @bitCast(entry.flags);
                    if (graph.multigraph_enabled) id_block.ids[slot] = entry.edge_id;
                    if (graph.edge_properties_enabled) prop_block.rows[slot] = entry.prop_row;
                }
                page_ops.setBlockAliveCount(graph, emit_block_idx, .fwd, @intCast(take));
            },
            .rev => {
                const block = page_ops.edgeBlockAt(graph, emit_block_idx, .rev);
                for (remaining[0..take], 0..) |entry, slot| block.sources[slot] = entry.key;
                page_ops.setBlockAliveCount(graph, emit_block_idx, .rev, @intCast(take));
            },
        }
        remaining = remaining[take..];
    }

    // Supersede the candidate blocks: fresh COW copies return to the free
    // stack immediately (never published); shared published blocks must wait
    // for the post-publish retire.
    for (block_list.items) |block_idx| {
        if (scratch.isTrackedBlock(side, block_idx)) {
            scratch.freeTrackedBlock(graph, side, block_idx);
        } else {
            try scratch.markRetireBlock(graph.allocator, side, block_idx);
        }
    }

    block_list.clearRetainingCapacity();
    for (0..span_count) |span_offset| {
        try block_list.append(graph.allocator, first_block_idx + @as(u32, @intCast(span_offset)));
    }
}

/// Applies the hard-bound fixups when needed and builds the side metadata:
/// occupancy-floor violations take the dense repack (which also restores
/// contiguity); a pure segment-bound overflow takes the cheap block-copy
/// coalesce.
pub fn buildSideFromBlockListBounded(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    comptime side: adjacency.AdjSide,
) !types.SideAdj {
    if (blockListNeedsRepack(graph, block_list.items, side)) {
        try repackBlockListDense(graph, scratch, block_list, side);
    } else if (blockListRunCount(block_list.items) > constants.MAX_SEGMENTS_PER_NODE) {
        try coalesceRunsByBlockCopy(graph, scratch, block_list, side);
    }
    return buildSideFromBlockList(graph, scratch, block_list.items);
}

pub fn cloneForwardBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    page_ops.edgeBlockAt(graph, new_block_idx, .fwd).* = page_ops.edgeBlockAtConst(graph, block_idx, .fwd).*;
    page_ops.setBlockAliveCount(graph, new_block_idx, .fwd, page_ops.blockAliveCount(graph, block_idx, .fwd));
    if (graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(graph, new_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).*;
    }
    if (graph.edge_properties_enabled) {
        page_ops.edgeBlockFwdPropsAt(graph, new_block_idx).* = page_ops.edgeBlockFwdPropsAtConst(graph, block_idx).*;
    }
    return new_block_idx;
}

pub fn cloneReverseBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .rev);
    page_ops.edgeBlockAt(graph, new_block_idx, .rev).* = page_ops.edgeBlockAtConst(graph, block_idx, .rev).*;
    page_ops.setBlockAliveCount(graph, new_block_idx, .rev, page_ops.blockAliveCount(graph, block_idx, .rev));
    return new_block_idx;
}
