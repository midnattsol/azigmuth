const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_published = @import("../../storage/node/published.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_runs = @import("../../adjacency/runs.zig");

const TombstoneScan = struct { found: bool = false };

pub const ForwardEntryView = side_ops.ForwardEntryView;

pub fn sideAdjOf(adjacency: types.NodeAdj, comptime side: Side) types.SideAdj {
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
    ctx: anytype,
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
        try callback(graph, ctx, run_desc.start, run_desc.count, run_idx + 1 == total_runs);
    }
}

pub fn forEachAliveSlotInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    comptime side: Side,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    try forEachRunInAdj(graph, adjacency, side, ctx, struct {
        fn run(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: @TypeOf(ctx),
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block_idx: u32 = @intCast(block_idx_usize);
                const alive_count = @min(blockAlive(inner_graph, block_idx, side), constants.EDGES_PER_BLOCK);
                for (0..alive_count) |slot| {
                    try callback(inner_graph, inner_ctx, block_idx, slot);
                }
            }
        }
    }.run);
}

pub fn forEachNodeIdInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    comptime side: Side,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    const side_adj = sideAdjOf(adjacency, side);
    if (side_adj.block_count == 0) return;

    if (node_published.NodePublished.isTiny(&side_adj)) {
        const count = node_published.NodePublished.tinyCount(&side_adj);
        switch (side) {
            .fwd => {
                const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
                for (0..count) |entry_idx| try callback(graph, ctx, slot.entries[entry_idx].destination);
            },
            .rev => {
                const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev);
                for (0..count) |entry_idx| try callback(graph, ctx, slot.sources[entry_idx]);
            },
        }
        return;
    }

    try side_ops.forEachNodeIdInSide(graph, side_adj, switch (side) {
        .fwd => .fwd,
        .rev => .rev,
    }, ctx, callback);
}

pub fn forEachForwardEntryInAdj(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    const side_adj = sideAdjOf(adjacency, .fwd);
    if (side_adj.block_count == 0) return;

    if (node_published.NodePublished.isTiny(&side_adj)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
        const count = node_published.NodePublished.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            const entry = slot.entries[entry_idx];
            try callback(graph, ctx, ForwardEntryView{
                .block_idx = side_adj.first_block,
                .slot = @intCast(entry_idx),
                .destination = entry.destination,
                .relation = entry.relation,
                .flags = entry.flags,
                .edge_id = entry.edge_id,
                .prop_row = entry.prop_row,
            });
        }
        return;
    }

    try side_ops.forEachForwardEntryInSide(graph, side_adj, ctx, callback);
}

fn scanForwardTombstone(
    graph: *const graph_core.GraphCore,
    scan: *TombstoneScan,
    block_idx: u32,
    slot: usize,
) !void {
    const destination_idx = page_ops.edgeBlockAtConst(graph, block_idx, .fwd).destinations[slot];
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
    forEachNodeIdInAdj(graph, adjacency, .fwd, &scan, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_scan: *TombstoneScan, destination_idx: u32) !void {
            if (destination_idx < inner_graph.publishedNodeCount() and node_validity.isNodeRemovedIndex(inner_graph, destination_idx)) {
                inner_scan.found = true;
                return error.TombstoneFound;
            }
        }
    }.callback) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return scan.found;
}

pub fn reverseHasTombstone(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj) bool {
    var scan = TombstoneScan{};
    forEachNodeIdInAdj(graph, adjacency, .rev, &scan, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_scan: *TombstoneScan, source_idx: u32) !void {
            if (source_idx < inner_graph.publishedNodeCount() and node_validity.isNodeRemovedIndex(inner_graph, source_idx)) {
                inner_scan.found = true;
                return error.TombstoneFound;
            }
        }
    }.callback) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return scan.found;
}

pub const Side = enum { fwd, rev };
pub const StackKindFast = enum { free, retired };

/// Fast-path ownership tracking is exact within a fixed low-index window so
/// the allocation-free validator keeps a bounded stack frame even under
/// profiles with multi-billion-block ceilings. Indices beyond the window are
/// skipped by the fast ownership/orphan checks; `debugValidate` (allocating)
/// remains the exhaustive path.
pub const MAX_TRACKED_BLOCKS: usize = @min(constants.MAX_EDGE_BLOCK_PAGES * constants.EDGE_BLOCKS_PER_PAGE, 1 << 18);
pub const TRACKED_BLOCK_BITMAP_WORDS: usize = (MAX_TRACKED_BLOCKS + 63) / 64;

pub const MAX_TRACKED_GROUPS: usize = @min(constants.MAX_EDGE_GROUP_PAGES * constants.EDGE_GROUPS_PER_PAGE, 1 << 19);
pub const TRACKED_GROUP_BITMAP_WORDS: usize = (MAX_TRACKED_GROUPS + 63) / 64;

pub const TraversedBlock = struct {
    block_idx: u32,
};

pub fn bitmapSet(bitmap: []u64, block_idx: u32) bool {
    const bit_idx: usize = @intCast(block_idx);
    // Beyond the tracked window: untracked, never reported as a duplicate.
    if (bit_idx >= bitmap.len * 64) return true;
    const word_idx = bit_idx / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_idx % 64));
    const already = (bitmap[word_idx] & mask) != 0;
    bitmap[word_idx] |= mask;
    return !already;
}

pub fn bitmapIsSet(bitmap: []const u64, block_idx: u32) bool {
    const bit_idx: usize = @intCast(block_idx);
    // Beyond the tracked window: pure membership query answers false.
    if (bit_idx >= bitmap.len * 64) return false;
    const word_idx = bit_idx / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_idx % 64));
    return (bitmap[word_idx] & mask) != 0;
}

pub fn readerEnter(graph: *const graph_core.GraphCore) types.GraphError!rcu.ReaderToken {
    return try rcu.readerEnter(@constCast(graph));
}

pub fn readerExit(graph: *const graph_core.GraphCore, token: rcu.ReaderToken) void {
    rcu.readerExit(@constCast(graph), token);
}

pub fn blockCount(adjacency: types.NodeAdj, comptime side: Side) u32 {
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

pub fn blockExists(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: Side) bool {
    return block_idx < allocatedBlockCount(graph, side);
}

pub fn blockAlive(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: Side) usize {
    return switch (side) {
        .fwd => page_ops.blockAliveCount(graph, block_idx, .fwd),
        .rev => page_ops.blockAliveCount(graph, block_idx, .rev),
    };
}

pub fn blockKey(graph: *const graph_core.GraphCore, block_idx: u32, slot: usize, comptime side: Side) u32 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd).destinations[slot],
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot],
    };
}

pub fn needsRepairFlag(adjacency: types.NodeAdj, comptime side: Side) bool {
    return switch (side) {
        .fwd => adjacency.flags.needs_repair_fwd,
        .rev => adjacency.flags.needs_repair_rev,
    };
}
