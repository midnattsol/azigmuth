const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_runs = @import("../../side_runs.zig");

const TombstoneScan = struct { found: bool = false };

fn sideAdjOf(adjacency: types.NodeAdj, comptime side: Side) types.SideAdj {
    return switch (side) {
        .fwd => .{
            .first_block = adjacency.first_block_fwd,
            .block_count = adjacency.block_count_fwd,
            .group_count = adjacency.group_count_fwd,
            .first_group = adjacency.first_group_fwd,
        },
        .rev => .{
            .first_block = adjacency.first_block_rev,
            .block_count = adjacency.block_count_rev,
            .group_count = adjacency.group_count_rev,
            .first_group = adjacency.first_group_rev,
        },
    };
}

pub fn forEachRunInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    comptime side: Side,
    context: anytype,
    comptime callback: anytype,
) !void {
    const side_adj = sideAdjOf(adjacency, side);
    if (side_adj.block_count == 0) return;

    try adjacency_mod.validateSideAdjLayoutForSide(graph, side_adj, switch (side) {
        .fwd => .fwd,
        .rev => .rev,
    });

    const total_runs = side_runs.runCount(side_adj);
    var run_idx: u16 = 0;
    while (run_idx < total_runs) : (run_idx += 1) {
        const run_desc = side_runs.runAt(graph, side_adj, run_idx) orelse return error.CorruptGraph;
        try callback(graph, context, run_desc.start, run_desc.count, run_idx + 1 == total_runs);
    }
}

pub fn forEachLiveSlotInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    comptime side: Side,
    context: anytype,
    comptime callback: anytype,
) !void {
    try forEachRunInAdj(graph, adjacency, side, context, struct {
        fn run(
            inner_graph: *const graph_core.GraphCore,
            inner_context: @TypeOf(context),
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block_idx: u32 = @intCast(block_idx_usize);
                const block = switch (side) {
                    .fwd => page_ops.edgeBlockAtConst(inner_graph, block_idx, .fwd),
                    .rev => page_ops.edgeBlockAtConst(inner_graph, block_idx, .rev),
                };
                const live_count = @popCount(block.mask);
                for (0..live_count) |slot| {
                    try callback(inner_graph, inner_context, block_idx, slot);
                }
            }
        }
    }.run);
}

fn scanForwardTombstone(
    graph: *const graph_core.GraphCore,
    scan: *TombstoneScan,
    block_idx: u32,
    slot: usize,
) !void {
    const destination_idx = page_ops.edgeBlockAtConst(graph, block_idx, .fwd).edges[slot].destination;
    if (destination_idx < graph.publishedNodeCount() and node_validity.isNodeRemovedIndex(graph, destination_idx)) {
        scan.found = true;
        return error.TombstoneFound;
    }
}

fn scanReverseTombstone(
    graph: *const graph_core.GraphCore,
    scan: *TombstoneScan,
    block_idx: u32,
    slot: usize,
) !void {
    const source_idx = page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot];
    if (source_idx < graph.publishedNodeCount() and node_validity.isNodeRemovedIndex(graph, source_idx)) {
        scan.found = true;
        return error.TombstoneFound;
    }
}

pub fn forwardHasTombstone(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj) bool {
    var scan = TombstoneScan{};
    forEachLiveSlotInAdj(graph, adjacency, .fwd, &scan, scanForwardTombstone) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return scan.found;
}

pub fn reverseHasTombstone(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj) bool {
    var scan = TombstoneScan{};
    forEachLiveSlotInAdj(graph, adjacency, .rev, &scan, scanReverseTombstone) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return scan.found;
}

pub const Side = enum { fwd, rev };
pub const StackKindFast = enum { free, retired };

pub const MAX_TRACKED_BLOCKS: usize = constants.MAX_EDGE_BLOCK_PAGES * constants.EDGE_BLOCKS_PER_PAGE;
pub const TRACKED_BLOCK_BITMAP_WORDS: usize = (MAX_TRACKED_BLOCKS + 63) / 64;

pub const MAX_TRACKED_GROUPS: usize = constants.MAX_EDGE_GROUP_PAGES * constants.EDGE_GROUPS_PER_PAGE;
pub const TRACKED_GROUP_BITMAP_WORDS: usize = (MAX_TRACKED_GROUPS + 63) / 64;

pub const TraversedBlock = struct {
    block_index: u32,
};

pub fn bitmapSet(bitmap: []u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    const already = (bitmap[word_index] & mask) != 0;
    bitmap[word_index] |= mask;
    return !already;
}

pub fn bitmapIsSet(bitmap: []const u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    return (bitmap[word_index] & mask) != 0;
}

pub fn readerEnter(graph: *const graph_core.GraphCore) types.GraphError!rcu.ReaderToken {
    return try rcu.readerEnter(@constCast(graph));
}

pub fn readerExit(graph: *const graph_core.GraphCore, token: rcu.ReaderToken) void {
    rcu.readerExit(@constCast(graph), token);
}

pub fn blockCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.block_count_fwd,
        .rev => adjacency.block_count_rev,
    };
}

pub fn groupCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.group_count_fwd,
        .rev => adjacency.group_count_rev,
    };
}

pub fn firstBlock(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_block_fwd,
        .rev => adjacency.first_block_rev,
    };
}

pub fn firstGroup(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_group_fwd,
        .rev => adjacency.first_group_rev,
    };
}

pub fn allocatedBlockCount(graph: *const graph_core.GraphCore, comptime side: Side) u32 {
    return switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };
}

pub fn blockExists(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) bool {
    return block_index < allocatedBlockCount(graph, side);
}

pub fn blockMask(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) u64 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).mask,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).mask,
    };
}

pub fn blockKey(graph: *const graph_core.GraphCore, block_index: u32, slot: usize, comptime side: Side) u32 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).edges[slot].destination,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).sources[slot],
    };
}

pub fn needsRepairFlag(adjacency: types.NodeAdj, comptime side: Side) bool {
    return switch (side) {
        .fwd => adjacency.flags.needs_repair_fwd,
        .rev => adjacency.flags.needs_repair_rev,
    };
}
