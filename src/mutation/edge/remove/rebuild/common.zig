const std = @import("std");
const constants = @import("../../../../core/constants.zig");
const adjacency = @import("../../../../adjacency/mod.zig");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const common = @import("../../../common.zig");

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
/// below the hard occupancy bound (RFC §3.6).
pub fn blockListNeedsRepack(
    graph: *const graph_core.GraphCore,
    block_list: []const u32,
    comptime side: adjacency.AdjSide,
) bool {
    if (block_list.len <= 1) return false;
    for (block_list[0 .. block_list.len - 1]) |block_idx| {
        const live = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, side).mask);
        if (live < constants.MIN_OCCUPANCY) return true;
    }
    return false;
}

const RepackEntry = struct {
    key: u32,
    relation: u16 = 0,
    flags: types.EdgeFlags = .{},
    edge_id: u32 = 0,
};

fn repackEntryLessThan(_: void, lhs: RepackEntry, rhs: RepackEntry) bool {
    if (lhs.key != rhs.key) return lhs.key < rhs.key;
    return lhs.edge_id < rhs.edge_id;
}

/// Synchronous in-call repair (allowed by RFC §3.6): repacks the candidate
/// block list into a fresh contiguous dense span so that no non-tail block is
/// published below the hard occupancy bound. Superseded shared blocks are
/// marked for retirement; superseded fresh blocks return to the free stack.
pub fn repackBlockListDense(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    comptime side: adjacency.AdjSide,
) !void {
    var total_live: usize = 0;
    for (block_list.items) |block_idx| {
        total_live += @popCount(page_ops.edgeBlockAtConst(graph, block_idx, side).mask);
    }
    if (total_live == 0) {
        block_list.clearRetainingCapacity();
        return;
    }

    const entries = try graph.allocator.alloc(RepackEntry, total_live);
    defer graph.allocator.free(entries);

    var entry_idx: usize = 0;
    for (block_list.items) |block_idx| {
        const live = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, side).mask);
        for (0..live) |slot| {
            entries[entry_idx] = switch (side) {
                .fwd => blk: {
                    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
                    break :blk .{
                        .key = block.destinations[slot],
                        .relation = block.relations[slot],
                        .flags = @bitCast(block.flags[slot]),
                        .edge_id = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).ids[slot] else 0,
                    };
                },
                .rev => .{ .key = page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot] },
            };
            entry_idx += 1;
        }
    }

    std.sort.pdq(RepackEntry, entries, {}, repackEntryLessThan);

    const span_count: u32 = @intCast((total_live + constants.EDGES_PER_BLOCK - 1) / constants.EDGES_PER_BLOCK);
    const first_block_idx = try scratch.allocFreshBlockSpan(graph, side, span_count);

    var remaining = entries;
    var emit_block_idx = first_block_idx;
    while (remaining.len > 0) : (emit_block_idx += 1) {
        const take = @min(remaining.len, constants.EDGES_PER_BLOCK);
        switch (side) {
            .fwd => {
                const block = page_ops.edgeBlockAt(graph, emit_block_idx, .fwd);
                const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, emit_block_idx) else undefined;
                for (remaining[0..take], 0..) |entry, slot| {
                    block.destinations[slot] = entry.key;
                    block.relations[slot] = entry.relation;
                    block.flags[slot] = @bitCast(entry.flags);
                    if (graph.multigraph_enabled) id_block.ids[slot] = entry.edge_id;
                }
                block.mask = constants.denseMask(@intCast(take));
            },
            .rev => {
                const block = page_ops.edgeBlockAt(graph, emit_block_idx, .rev);
                for (remaining[0..take], 0..) |entry, slot| block.sources[slot] = entry.key;
                block.mask = constants.denseMask(@intCast(take));
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

/// Applies the hard-bound repack when needed and builds the side metadata.
pub fn buildSideFromBlockListBounded(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    comptime side: adjacency.AdjSide,
) !types.SideAdj {
    if (blockListNeedsRepack(graph, block_list.items, side)) {
        try repackBlockListDense(graph, scratch, block_list, side);
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
    if (graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(graph, new_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).*;
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
    return new_block_idx;
}
