//! Structural validation of graph invariants.
//!
//! Two levels of checking are provided:
//!   - `validate`  — fast path: returns `error.CorruptGraph` on the first
//!     violation. Does not allocate.
//!   - `debugValidate` — exhaustive: allocates and returns every violation.

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");
const rcu = @import("rcu.zig");
const adjacency_mod = @import("adjacency.zig");
const node_validity = @import("node_validity.zig");

fn forwardHasTombstone(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj) bool {
    const block_count = adjacency.block_count_fwd;
    if (block_count == 0) return false;
    const first_block = adjacency.first_block_fwd;
    const group_count = adjacency.group_count_fwd;
    const first_group = adjacency.first_group_fwd;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const dst = block.edges[slot].destination;
                if (dst < graph.publishedNodeCount() and
                    page_ops.nodeAtConst(graph, .{ .index = dst }).publishedAdj().flags.removed) return true;
            }
        }
        return false;
    }

    var group_idx = first_group;
    var visited: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= group_count or group_idx >= graph.group_count) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const dst = block.edges[slot].destination;
                if (dst < graph.publishedNodeCount() and
                    page_ops.nodeAtConst(graph, .{ .index = dst }).publishedAdj().flags.removed) return true;
            }
        }
        group_idx = group.next;
    }
    return false;
}

const Side = enum { fwd, rev };
const StackKindFast = enum { free, retired };

const MAX_TRACKED_BLOCKS: usize = constants.MAX_EDGE_BLOCK_PAGES * constants.EDGE_BLOCKS_PER_PAGE;
const TRACKED_BLOCK_BITMAP_WORDS: usize = (MAX_TRACKED_BLOCKS + 63) / 64;

const MAX_TRACKED_GROUPS: usize = constants.MAX_EDGE_GROUP_PAGES * constants.EDGE_GROUPS_PER_PAGE;
const TRACKED_GROUP_BITMAP_WORDS: usize = (MAX_TRACKED_GROUPS + 63) / 64;

const TraversedBlock = struct {
    block_index: u32,
};

fn bitmapSet(bitmap: []u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    const already = (bitmap[word_index] & mask) != 0;
    bitmap[word_index] |= mask;
    return !already;
}

fn bitmapIsSet(bitmap: []const u64, block_index: u32) bool {
    const bit_index: usize = @intCast(block_index);
    const word_index = bit_index / 64;
    const mask = @as(u64, 1) << @as(u6, @intCast(bit_index % 64));
    return (bitmap[word_index] & mask) != 0;
}

fn readerEnter(graph: *const graph_core.GraphCore) rcu.ReaderToken {
    return rcu.readerEnter(@constCast(graph));
}

fn readerExit(graph: *const graph_core.GraphCore, token: rcu.ReaderToken) void {
    rcu.readerExit(@constCast(graph), token);
}

fn blockCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.block_count_fwd,
        .rev => adjacency.block_count_rev,
    };
}

fn groupCount(adjacency: types.NodeAdj, comptime side: Side) u16 {
    return switch (side) {
        .fwd => adjacency.group_count_fwd,
        .rev => adjacency.group_count_rev,
    };
}

fn firstBlock(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_block_fwd,
        .rev => adjacency.first_block_rev,
    };
}

fn firstGroup(adjacency: types.NodeAdj, comptime side: Side) u32 {
    return switch (side) {
        .fwd => adjacency.first_group_fwd,
        .rev => adjacency.first_group_rev,
    };
}

fn allocatedBlockCount(graph: *const graph_core.GraphCore, comptime side: Side) u32 {
    return switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };
}

fn blockExists(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) bool {
    return block_index < allocatedBlockCount(graph, side);
}

fn blockMask(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) u64 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).mask,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).mask,
    };
}

fn blockKey(graph: *const graph_core.GraphCore, block_index: u32, slot: usize, comptime side: Side) u32 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd).edges[slot].destination,
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev).sources[slot],
    };
}

fn validateBlockDense(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) !void {
    if (!blockExists(graph, block_index, side)) return error.CorruptGraph;

    const mask = blockMask(graph, block_index, side);
    const live_count = @popCount(mask);
    if (mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
}

fn validateDenseInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: Side,
) !void {
    for (start..start + count) |block_index| {
        try validateBlockDense(graph, @intCast(block_index), side);
    }
}

fn validateDenseInGroupChain(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    comptime side: Side,
) !void {
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups > graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        try validateDenseInContiguousBlocks(graph, group.start, group.count, side);
        group_index = group.next;
    }
}

fn validateDenseMasks(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: Side) !void {
    if (blockCount(adjacency, side) == 0) return;

    if (groupCount(adjacency, side) == 0) {
        return validateDenseInContiguousBlocks(graph, firstBlock(adjacency, side), blockCount(adjacency, side), side);
    }

    return validateDenseInGroupChain(graph, firstGroup(adjacency, side), side);
}

fn validateBlockShapeFast(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) !u64 {
    if (!blockExists(graph, block_index, side)) return error.CorruptGraph;
    const node_count = graph.publishedNodeCount();

    if (side == .fwd) {
        const block = page_ops.edgeBlockAtConst(graph, block_index, .fwd);
        const live_count = @popCount(block.mask);
        if (block.mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
        var prev: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.edges[slot].destination;
            if (key >= node_count) return error.CorruptGraph;
            if (slot > 0 and key <= prev) return error.CorruptGraph;
            prev = key;
        }
        return live_count;
    } else {
        const block = page_ops.edgeBlockAtConst(graph, block_index, .rev);
        const live_count = @popCount(block.mask);
        if (block.mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
        var prev: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.sources[slot];
            if (key >= node_count) return error.CorruptGraph;
            if (slot > 0 and key <= prev) return error.CorruptGraph;
            prev = key;
        }
        return live_count;
    }
}

fn validateContiguousBlocksFast(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: Side,
) !u64 {
    var total: u64 = 0;
    for (start..start + count) |block_index| {
        total += try validateBlockShapeFast(graph, @intCast(block_index), side);
    }
    return total;
}

fn validateGroupChainFast(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    expected_group_count: u16,
    comptime side: Side,
) !u64 {
    var total: u64 = 0;
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        total += try validateContiguousBlocksFast(graph, group.start, group.count, side);
        group_index = group.next;
    }

    if (visited_groups != expected_group_count) return error.CorruptGraph;
    return total;
}

fn validateAdjacencyBlocksFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: Side) !u64 {
    if (blockCount(adjacency, side) == 0) return 0;

    if (groupCount(adjacency, side) == 0) {
        return validateContiguousBlocksFast(graph, firstBlock(adjacency, side), blockCount(adjacency, side), side);
    }

    return validateGroupChainFast(graph, firstGroup(adjacency, side), groupCount(adjacency, side), side);
}

fn validateOccupancyFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: Side) !void {
    const count = blockCount(adjacency, side);
    if (count <= 1) return;

    if (groupCount(adjacency, side) == 0) {
        const end = firstBlock(adjacency, side) + count - 1;
        for (firstBlock(adjacency, side)..end) |block_index| {
            if (@popCount(blockMask(graph, @intCast(block_index), side)) < constants.MIN_OCCUPANCY) return error.CorruptGraph;
        }
        return;
    }

    var group_index = firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        const is_last_group = group.next == constants.END_OF_CHAIN;
        const end = if (is_last_group) group.start + group.count - 1 else group.start + group.count;
        for (group.start..end) |block_index| {
            if (@popCount(blockMask(graph, @intCast(block_index), side)) < constants.MIN_OCCUPANCY) return error.CorruptGraph;
        }
        group_index = group.next;
    }
}

fn sumBlockLive(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) u64 {
    if (!blockExists(graph, block_index, side)) return 0;
    return @popCount(blockMask(graph, block_index, side));
}

fn sumContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: Side,
) u64 {
    var total: u64 = 0;
    for (start..start + count) |block_index| {
        total += sumBlockLive(graph, @intCast(block_index), side);
    }
    return total;
}

fn sumGroupChain(graph: *const graph_core.GraphCore, first_group: u32, comptime side: Side) u64 {
    var total: u64 = 0;
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return total;
        if (visited_groups > graph.group_count) return total;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        total += sumContiguousBlocks(graph, group.start, group.count, side);
        group_index = group.next;
    }

    return total;
}

fn sumAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: Side) u64 {
    if (blockCount(adjacency, side) == 0) return 0;

    if (groupCount(adjacency, side) == 0) {
        return sumContiguousBlocks(graph, firstBlock(adjacency, side), blockCount(adjacency, side), side);
    }

    return sumGroupChain(graph, firstGroup(adjacency, side), side);
}

fn countVisibleEntriesInBlock(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) u64 {
    const block = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd),
        .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev),
    };
    const live = @popCount(block.mask);
    var total: u64 = 0;
    for (0..live) |slot| {
        const candidate_index = switch (side) {
            .fwd => block.edges[slot].destination,
            .rev => block.sources[slot],
        };
        if (node_validity.isNodeLiveIndex(graph, candidate_index)) total += 1;
    }
    return total;
}

fn sumVisibleAdjacency(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: Side) u64 {
    if (adjacency.flags.removed) return 0;
    if (blockCount(adjacency, side) == 0) return 0;

    var total: u64 = 0;
    if (groupCount(adjacency, side) == 0) {
        const start = firstBlock(adjacency, side);
        for (start..start + blockCount(adjacency, side)) |block_index| {
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        return total;
    }

    var group_index = firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return total;
        if (visited_groups >= graph.group_count or visited_groups >= groupCount(adjacency, side)) return total;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        group_index = group.next;
    }
    return total;
}

fn needsRepairFlag(adjacency: types.NodeAdj, comptime side: Side) bool {
    return switch (side) {
        .fwd => adjacency.flags.needs_repair_fwd,
        .rev => adjacency.flags.needs_repair_rev,
    };
}

fn blockStackHeadIndex(graph: *const graph_core.GraphCore, comptime kind: StackKindFast, comptime side: Side) u32 {
    const head = switch (kind) {
        .free => switch (side) {
            .fwd => graph.free_blocks_fwd_head.load(.acquire),
            .rev => graph.free_blocks_rev_head.load(.acquire),
        },
        .retired => switch (side) {
            .fwd => graph.retired_blocks_fwd_head.load(.acquire),
            .rev => graph.retired_blocks_rev_head.load(.acquire),
        },
    };
    return @truncate(head);
}

fn blockMetaNextFast(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) !u32 {
    if (!blockExists(graph, block_index, side)) return error.CorruptGraph;
    const page_index = page_ops.pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    const raw = switch (side) {
        .fwd => graph.edge_blocks_fwd_meta_pages[@intCast(page_index)].load(.acquire),
        .rev => graph.edge_blocks_rev_meta_pages[@intCast(page_index)].load(.acquire),
    };
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_BLOCKS_PER_PAGE];
    return page[page_ops.slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)].next.load(.acquire);
}

fn populateStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: StackKindFast,
    comptime side: Side,
) !void {
    const limit = allocatedBlockCount(graph, side);
    var current = blockStackHeadIndex(graph, kind, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) {
        if (visited >= limit) return error.CorruptGraph;
        visited += 1;
        if (!bitmapSet(bitmap, current)) return error.CorruptGraph;
        current = try blockMetaNextFast(graph, current, side);
    }
}

fn groupStackHeadIndexFast(graph: *const graph_core.GraphCore, comptime kind: StackKindFast) u32 {
    const head = switch (kind) {
        .free => graph.free_groups_head.load(.acquire),
        .retired => graph.retired_groups_head.load(.acquire),
    };
    return @truncate(head);
}

fn groupMetaNextFast(graph: *const graph_core.GraphCore, group_index: u32) !u32 {
    if (group_index >= graph.group_count) return error.CorruptGraph;
    const page_index = page_ops.pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    const raw = graph.edge_block_group_meta_pages[@intCast(page_index)].load(.acquire);
    if (raw == 0) return error.CorruptGraph;
    const page_ptr: [*]const types.BlockMeta = @ptrFromInt(raw);
    const page = page_ptr[0..constants.EDGE_GROUPS_PER_PAGE];
    return page[page_ops.slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)].next.load(.acquire);
}

fn populateGroupStackBitmapFast(
    graph: *const graph_core.GraphCore,
    bitmap: []u64,
    comptime kind: StackKindFast,
) !void {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var current = groupStackHeadIndexFast(graph, kind);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) {
        if (visited >= limit) return error.CorruptGraph;
        visited += 1;
        if (!bitmapSet(bitmap, current)) return error.CorruptGraph;
        current = try groupMetaNextFast(graph, current);
    }
}

fn validateOwnedBlockFast(
    graph: *const graph_core.GraphCore,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    block_index: u32,
    comptime side: Side,
) !void {
    if (!blockExists(graph, block_index, side)) return error.CorruptGraph;
    if (!bitmapSet(owned_blocks, block_index)) return error.CorruptGraph;
    if (bitmapIsSet(free_blocks, block_index)) return error.CorruptGraph;
    if (bitmapIsSet(retired_blocks, block_index)) return error.CorruptGraph;
}

fn validateAdjacencyOwnershipAndLayoutFast(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    owned_blocks: []u64,
    free_blocks: []const u64,
    retired_blocks: []const u64,
    owned_groups: []u64,
    free_groups: []const u64,
    retired_groups: []const u64,
    comptime side: Side,
) !void {
    const count = blockCount(adjacency, side);
    const groups = groupCount(adjacency, side);
    if (count == 0) {
        if (groups != 0) return error.CorruptGraph;
        return;
    }

    if (groups == 0) {
        for (firstBlock(adjacency, side)..firstBlock(adjacency, side) + count) |block_index| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_index), side);
        }
        return;
    }

    if (groups > constants.MAX_GROUPS_PER_NODE and !needsRepairFlag(adjacency, side)) {
        if (!adjacency.flags.removed) return error.CorruptGraph;
    }

    var group_index = firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    var counted_blocks: u16 = 0;
    var previous_group_end: ?u32 = null;
    var chain_is_contiguous = true;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count or visited_groups >= groups) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;

        if (!bitmapSet(owned_groups, group_index)) return error.CorruptGraph;
        if (bitmapIsSet(free_groups, group_index)) return error.CorruptGraph;
        if (bitmapIsSet(retired_groups, group_index)) return error.CorruptGraph;

        const is_last_group = group.next == constants.END_OF_CHAIN;
        if (!is_last_group and group.count < 4 and !needsRepairFlag(adjacency, side)) {
            if (!adjacency.flags.removed) return error.CorruptGraph;
        }

        if (previous_group_end) |expected_start| {
            if (group.start != expected_start) chain_is_contiguous = false;
        }
        previous_group_end = group.start + group.count;

        for (group.start..group.start + group.count) |block_index| {
            try validateOwnedBlockFast(graph, owned_blocks, free_blocks, retired_blocks, @intCast(block_index), side);
        }
        counted_blocks += group.count;

        group_index = group.next;
    }

    if (visited_groups != groups) return error.CorruptGraph;
    if (counted_blocks != count) return error.CorruptGraph;
    if (chain_is_contiguous and !needsRepairFlag(adjacency, side)) {
        if (!adjacency.flags.removed) return error.CorruptGraph;
    }
}

fn validateRepairDebtFast(graph: *const graph_core.GraphCore, node_count: u32) !void {
    for (graph.repair_fwd.items) |node_index| {
        if (node_index >= node_count) return error.CorruptGraph;
    }
    for (graph.repair_rev.items) |node_index| {
        if (node_index >= node_count) return error.CorruptGraph;
    }
}

fn appendBlockShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    block_index: u32,
    comptime side: Side,
) !void {
    if (!blockExists(graph, block_index, side)) return;

    const mask = blockMask(graph, block_index, side);
    const live_count = @popCount(mask);

    if (mask != constants.denseMask(@intCast(live_count))) {
        try violations.append(allocator, .{ .mask_bit_out_of_range = .{ .node = node_id, .block = block_index } });
    }

    for (0..live_count) |slot| {
        const key = blockKey(graph, block_index, slot, side);
        if (key >= graph.publishedNodeCount()) {
            try violations.append(allocator, .{ .invalid_dst = .{ .node = node_id, .block = block_index, .slot = @intCast(slot), .dst = key } });
        }
        if (slot > 0 and key <= blockKey(graph, block_index, slot - 1, side)) {
            try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_index, .slot = @intCast(slot) } });
        }
    }
}

fn appendContiguousBlocks(
    blocks: *std.ArrayList(TraversedBlock),
    allocator: std.mem.Allocator,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_index| {
        try blocks.append(allocator, .{ .block_index = @intCast(block_index) });
    }
}

const DebugGroupSpan = struct {
    group: u32,
    start: u32,
    count: u16,
};

fn spansOverlap(a: DebugGroupSpan, b: DebugGroupSpan) bool {
    const a_end = a.start + a.count;
    const b_end = b.start + b.count;
    return a.start < b_end and b.start < a_end;
}

fn collectAdjacencyBlocks(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    blocks: *std.ArrayList(TraversedBlock),
    comptime side: Side,
) !void {
    if (blockCount(adjacency, side) == 0) return;

    if (groupCount(adjacency, side) == 0) {
        try appendContiguousBlocks(blocks, allocator, firstBlock(adjacency, side), blockCount(adjacency, side));
        return;
    }

    var seen_spans: [64]DebugGroupSpan = undefined;
    var seen_count: usize = 0;
    const expected_groups = groupCount(adjacency, side);
    var visited_groups: u32 = 0;
    var group_index = firstGroup(adjacency, side);

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        if (visited_groups >= graph.group_count or visited_groups > expected_groups) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        const current_span = DebugGroupSpan{ .group = group_index, .start = group.start, .count = group.count };
        const comparable_count = @min(seen_count, seen_spans.len);
        for (seen_spans[0..comparable_count]) |seen| {
            if (spansOverlap(seen, current_span)) {
                try violations.append(allocator, .{ .blockgroup_overlap = .{ .node = node_id, .group_a = seen.group, .group_b = group_index } });
            }
        }
        if (seen_count < seen_spans.len) seen_spans[seen_count] = current_span;
        seen_count += 1;

        for (group.start..group.start + group.count) |block_index_usize| {
            try blocks.append(allocator, .{ .block_index = @intCast(block_index_usize) });
        }

        group_index = group.next;
    }
}

fn buildFreeBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: Side,
) !std.DynamicBitSetUnmanaged {
    const limit = allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = blockStackHeadIndex(graph, .free, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

fn buildRetiredBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: Side,
) !std.DynamicBitSetUnmanaged {
    const limit = allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = blockStackHeadIndex(graph, .retired, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

fn buildFreeGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = groupStackHeadIndexFast(graph, .free);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = groupMetaNextFast(graph, current) catch break;
    }
    return set;
}

fn buildRetiredGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = groupStackHeadIndexFast(graph, .retired);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = groupMetaNextFast(graph, current) catch break;
    }
    return set;
}

fn markOwnedBlock(
    owned_blocks: *std.DynamicBitSetUnmanaged,
    block_index: u32,
) bool {
    const bit_index: usize = @intCast(block_index);
    if (owned_blocks.isSet(bit_index)) return false;
    owned_blocks.set(bit_index);
    return true;
}

fn appendOwnershipAndShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    owned_blocks: *std.DynamicBitSetUnmanaged,
    free_blocks: *const std.DynamicBitSetUnmanaged,
    retired_blocks: *const std.DynamicBitSetUnmanaged,
    node_id: u32,
    blocks: []const TraversedBlock,
    comptime side: Side,
) !void {
    const tail_block_index = if (blocks.len > 0) blocks[blocks.len - 1].block_index else constants.END_OF_CHAIN;

    for (blocks) |traversed_block| {
        const block_index = traversed_block.block_index;
        if (!blockExists(graph, block_index, side)) continue;

        if (!markOwnedBlock(owned_blocks, block_index)) {
            try violations.append(allocator, .{ .block_double_owned = .{ .block = block_index } });
        }

        const bit_index: usize = @intCast(block_index);
        if (bit_index < free_blocks.bit_length and free_blocks.isSet(bit_index)) {
            try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = block_index } });
        }

        if (bit_index < retired_blocks.bit_length and retired_blocks.isSet(bit_index)) {
            try violations.append(allocator, .{ .retired_block_reachable = .{ .block = block_index, .node = node_id } });
        }

        try appendBlockShapeViolations(graph, allocator, violations, node_id, block_index, side);

        const live_count = @popCount(blockMask(graph, block_index, side));
        const non_tail_underfull = blocks.len > 1 and block_index != tail_block_index and live_count < constants.MIN_OCCUPANCY;
        if (non_tail_underfull) {
            try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = block_index, .occupancy = @intCast(live_count) } });
        }
    }
}

fn runContainsTarget(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: Side,
) bool {
    return switch (side) {
        .fwd => findSlotInRun(graph, start, count, target, types.EdgeBlockFwd, .fwd) != null,
        .rev => findSlotInRun(graph, start, count, target, types.EdgeBlockRev, .rev) != null,
    };
}

/// Searches a run of `count` blocks for `target`.  Tries binary search
/// on block key ranges first, then falls back to a linear scan because
/// blocks may not be globally sorted by key (e.g. after an append to a
/// contiguous run creates a new block with a smaller key).
fn findSlotInRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime BlockType: type,
    comptime side: Side,
) ?u7 {
    if (count == 0) return null;

    // Binary search (fast path).
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block_index = start + mid;
        const block = switch (side) {
            .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd),
            .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev),
        };
        const live = @as(u7, @intCast(@popCount(block.mask)));
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
            if (adjacency_mod.searchInBlock(BlockType, block, target)) |slot| return slot;
            break;
        }
    }
    // Fallback: linear scan of the run.
    for (start..start + count) |block_index_usize| {
        const block_index: u32 = @intCast(block_index_usize);
        const block = switch (side) {
            .fwd => page_ops.edgeBlockAtConst(graph, block_index, .fwd),
            .rev => page_ops.edgeBlockAtConst(graph, block_index, .rev),
        };
        if (adjacency_mod.searchInBlock(BlockType, block, target)) |slot| return slot;
    }
    return null;
}

fn adjacencyContains(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, target: u32, comptime side: Side) bool {
    const count = blockCount(adjacency, side);
    if (count == 0) return false;

    if (groupCount(adjacency, side) == 0) {
        return runContainsTarget(graph, firstBlock(adjacency, side), count, target, side);
    }

    var group_index = firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return false;
        if (visited_groups > graph.group_count) return false;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (runContainsTarget(graph, group.start, group.count, target, side)) return true;
        group_index = group.next;
    }
    return false;
}

fn appendForwardConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    source_node: u32,
    blocks: []const TraversedBlock,
) !void {
    for (blocks) |traversed_block| {
        if (!blockExists(graph, traversed_block.block_index, .fwd)) continue;

        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .fwd);
        const live_count = @popCount(block.mask);

        for (0..live_count) |slot| {
            const destination_node = block.edges[slot].destination;
            if (destination_node >= graph.publishedNodeCount()) continue;

            const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
            if (!adjacencyContains(graph, destination_adjacency, source_node, .rev)) {
                try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = source_node, .dst = destination_node } });
            }
        }
    }
}

fn appendReverseConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    destination_node: u32,
    blocks: []const TraversedBlock,
) !void {
    for (blocks) |traversed_block| {
        if (!blockExists(graph, traversed_block.block_index, .rev)) continue;

        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .rev);
        const live_count = @popCount(block.mask);

        for (0..live_count) |slot| {
            const source_node = block.sources[slot];
            if (source_node >= graph.publishedNodeCount()) continue;

            const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
            if (!adjacencyContains(graph, source_adjacency, destination_node, .fwd)) {
                try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = source_node, .dst = destination_node } });
            }
        }
    }
}

fn appendRepairDebtViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
) !void {
    const node_count = graph.publishedNodeCount();
    for (graph.repair_fwd.items) |node_index| {
        if (node_index >= node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_index } });
        }
    }
    for (graph.repair_rev.items) |node_index| {
        if (node_index >= node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_index } });
        }
    }
}

fn appendLayoutDebtViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    comptime side: Side,
) !void {
    const groups = groupCount(adjacency, side);
    if (groups == 0) return;

    var group_index = firstGroup(adjacency, side);
    var visited_groups: u32 = 0;
    var previous_group_end: ?u32 = null;
    var chain_is_contiguous = true;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        if (visited_groups >= graph.group_count or visited_groups >= groups) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        const is_last_group = group.next == constants.END_OF_CHAIN;
        if (!is_last_group and group.count < 4 and !needsRepairFlag(adjacency, side)) {
            try violations.append(allocator, .{ .run_fragmentation_requires_repair = .{
                .node = node_id,
                .group = group_index,
                .count = group.count,
            } });
        }
        if (previous_group_end) |expected_start| {
            if (group.start != expected_start) chain_is_contiguous = false;
        }
        previous_group_end = group.start + group.count;
        group_index = group.next;
    }

    if (chain_is_contiguous and !needsRepairFlag(adjacency, side)) {
        try violations.append(allocator, .{ .grouped_layout_needs_canonicalization = .{
            .node = node_id,
            .first_group = firstGroup(adjacency, side),
        } });
    }
}

fn validateForwardConsistencyFast(graph: *const graph_core.GraphCore, source_node: u32, adjacency: types.NodeAdj) !void {
    if (blockCount(adjacency, .fwd) == 0) return;

    if (groupCount(adjacency, .fwd) == 0) {
        return validateForwardConsistencyInContiguousBlocks(graph, source_node, firstBlock(adjacency, .fwd), blockCount(adjacency, .fwd));
    }

    var group_index = firstGroup(adjacency, .fwd);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        try validateForwardConsistencyInContiguousBlocks(graph, source_node, group.start, group.count);
        group_index = group.next;
    }
}

fn validateForwardConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, start: u32, count: u16) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            const destination_node = block.edges[slot].destination;
            if (destination_node >= graph.publishedNodeCount()) return error.CorruptGraph;

            const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
            if (!adjacencyContains(graph, destination_adjacency, source_node, .rev)) return error.CorruptGraph;
        }
    }
}

fn validateReverseConsistencyFast(graph: *const graph_core.GraphCore, destination_node: u32, adjacency: types.NodeAdj) !void {
    if (blockCount(adjacency, .rev) == 0) return;

    if (groupCount(adjacency, .rev) == 0) {
        return validateReverseConsistencyInContiguousBlocks(graph, destination_node, firstBlock(adjacency, .rev), blockCount(adjacency, .rev));
    }

    var group_index = firstGroup(adjacency, .rev);
    var visited_groups: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_groups >= graph.group_count) return error.CorruptGraph;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        try validateReverseConsistencyInContiguousBlocks(graph, destination_node, group.start, group.count);
        group_index = group.next;
    }
}

fn validateReverseConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, destination_node: u32, start: u32, count: u16) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .rev);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            const source_node = block.sources[slot];
            if (source_node >= graph.publishedNodeCount()) return error.CorruptGraph;

            const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
            if (!adjacencyContains(graph, source_adjacency, destination_node, .fwd)) return error.CorruptGraph;
        }
    }
}

pub fn validate(graph: *const graph_core.GraphCore) !void {
    const reader_token = readerEnter(graph);
    defer readerExit(graph, reader_token);

    const node_count = graph.publishedNodeCount();
    var total_forward: u64 = 0;
    var total_reverse: u64 = 0;
    var total_visible_forward: u64 = 0;
    var total_visible_reverse: u64 = 0;
    var owned_forward_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;
    var owned_reverse_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;
    var free_forward_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;
    var free_reverse_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;
    var retired_forward_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;
    var retired_reverse_blocks: [TRACKED_BLOCK_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_BLOCK_BITMAP_WORDS;

    var owned_groups: [TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_GROUP_BITMAP_WORDS;
    var free_groups: [TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_GROUP_BITMAP_WORDS;
    var retired_groups: [TRACKED_GROUP_BITMAP_WORDS]u64 = [_]u64{0} ** TRACKED_GROUP_BITMAP_WORDS;

    try populateStackBitmapFast(graph, free_forward_blocks[0..], .free, .fwd);
    try populateStackBitmapFast(graph, free_reverse_blocks[0..], .free, .rev);
    try populateStackBitmapFast(graph, retired_forward_blocks[0..], .retired, .fwd);
    try populateStackBitmapFast(graph, retired_reverse_blocks[0..], .retired, .rev);
    try populateGroupStackBitmapFast(graph, free_groups[0..], .free);
    try populateGroupStackBitmapFast(graph, retired_groups[0..], .retired);

    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const node_buffer = page_ops.nodeAtConst(graph, .{ .index = node_id });
        const adjacency = node_buffer.publishedAdj();

        const fwd_live = try validateAdjacencyBlocksFast(graph, adjacency, .fwd);
        const rev_live = try validateAdjacencyBlocksFast(graph, adjacency, .rev);
        total_forward += fwd_live;
        total_reverse += rev_live;
        total_visible_forward += sumVisibleAdjacency(graph, adjacency, .fwd);
        total_visible_reverse += sumVisibleAdjacency(graph, adjacency, .rev);
        try validateAdjacencyOwnershipAndLayoutFast(graph, adjacency, owned_forward_blocks[0..], free_forward_blocks[0..], retired_forward_blocks[0..], owned_groups[0..], free_groups[0..], retired_groups[0..], .fwd);
        try validateAdjacencyOwnershipAndLayoutFast(graph, adjacency, owned_reverse_blocks[0..], free_reverse_blocks[0..], retired_reverse_blocks[0..], owned_groups[0..], free_groups[0..], retired_groups[0..], .rev);
        try validateOccupancyFast(graph, adjacency, .fwd);
        try validateOccupancyFast(graph, adjacency, .rev);
        try validateForwardConsistencyFast(graph, node_id, adjacency);
        try validateReverseConsistencyFast(graph, node_id, adjacency);

        if (adjacency.flags.removed) {
            if (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or node_buffer.degree_fwd != 0) {
                return error.CorruptGraph;
            }
            if (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev) {
                return error.CorruptGraph;
            }
        }

        const fwd_visible = sumVisibleAdjacency(graph, adjacency, .fwd);
        const rev_visible = sumVisibleAdjacency(graph, adjacency, .rev);
        if (!adjacency.flags.removed) {
            if (fwd_visible < constants.DEGREE_OVERFLOW and node_buffer.degree_fwd != fwd_visible) {
                return error.CorruptGraph;
            }
            if (rev_visible < constants.DEGREE_OVERFLOW and node_buffer.degree_rev != rev_visible) {
                return error.CorruptGraph;
            }
            // RFC §6.3, §A.26: a live predecessor with a forward reference
            // to a removed node MUST have needs_repair_fwd set.
            if (!adjacency.flags.needs_repair_fwd and forwardHasTombstone(graph, adjacency)) {
                return error.CorruptGraph;
            }
        }
    }

    try validateRepairDebtFast(graph, node_count);

    {
        const fwd_limit = allocatedBlockCount(graph, .fwd);
        for (0..fwd_limit) |block_index| {
            if (!bitmapIsSet(owned_forward_blocks[0..], @intCast(block_index)) and
                !bitmapIsSet(free_forward_blocks[0..], @intCast(block_index)) and
                !bitmapIsSet(retired_forward_blocks[0..], @intCast(block_index)))
            {
                return error.CorruptGraph;
            }
        }
    }
    {
        const rev_limit = allocatedBlockCount(graph, .rev);
        for (0..rev_limit) |block_index| {
            if (!bitmapIsSet(owned_reverse_blocks[0..], @intCast(block_index)) and
                !bitmapIsSet(free_reverse_blocks[0..], @intCast(block_index)) and
                !bitmapIsSet(retired_reverse_blocks[0..], @intCast(block_index)))
            {
                return error.CorruptGraph;
            }
        }
    }
    {
        const group_limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
        for (0..group_limit) |group_index| {
            if (!bitmapIsSet(owned_groups[0..], @intCast(group_index)) and
                !bitmapIsSet(free_groups[0..], @intCast(group_index)) and
                !bitmapIsSet(retired_groups[0..], @intCast(group_index)))
            {
                return error.CorruptGraph;
            }
        }
    }

    if (total_forward != total_reverse) return error.CorruptGraph;
    if (total_visible_forward != total_visible_reverse) return error.CorruptGraph;
    if (total_visible_forward != graph.edge_count.load(.acquire)) return error.CorruptGraph;
}

pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    const reader_token = readerEnter(graph);
    defer readerExit(graph, reader_token);

    var violations: std.ArrayList(types.Violation) = .empty;
    errdefer violations.deinit(allocator);
    var total_visible_fwd: u64 = 0;
    var total_visible_rev: u64 = 0;

    var owned_forward_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire));
    defer owned_forward_blocks.deinit(allocator);
    var owned_reverse_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire));
    defer owned_reverse_blocks.deinit(allocator);

    var free_forward_blocks = try buildFreeBlockSet(graph, allocator, .fwd);
    defer free_forward_blocks.deinit(allocator);
    var free_reverse_blocks = try buildFreeBlockSet(graph, allocator, .rev);
    defer free_reverse_blocks.deinit(allocator);
    var retired_forward_blocks = try buildRetiredBlockSet(graph, allocator, .fwd);
    defer retired_forward_blocks.deinit(allocator);
    var retired_reverse_blocks = try buildRetiredBlockSet(graph, allocator, .rev);
    defer retired_reverse_blocks.deinit(allocator);

    const group_limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var owned_groups_debug = try std.DynamicBitSetUnmanaged.initEmpty(allocator, group_limit);
    defer owned_groups_debug.deinit(allocator);
    var free_groups_debug = try buildFreeGroupSet(graph, allocator);
    defer free_groups_debug.deinit(allocator);
    var retired_groups_debug = try buildRetiredGroupSet(graph, allocator);
    defer retired_groups_debug.deinit(allocator);

    const node_count = graph.publishedNodeCount();

    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        var forward_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer forward_blocks.deinit(allocator);
        var reverse_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer reverse_blocks.deinit(allocator);

        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &forward_blocks, .fwd);
        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &reverse_blocks, .rev);

        if (forward_blocks.items.len != adjacency.block_count_fwd) {
            try violations.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = adjacency.block_count_fwd, .actual = @intCast(forward_blocks.items.len) } });
        }
        if (reverse_blocks.items.len != adjacency.block_count_rev) {
            try violations.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = adjacency.block_count_rev, .actual = @intCast(reverse_blocks.items.len) } });
        }

        if (adjacency.group_count_fwd > 0) {
            var group_idx = adjacency.first_group_fwd;
            var visited_groups: u32 = 0;
            while (group_idx != constants.END_OF_CHAIN and visited_groups < adjacency.group_count_fwd) : (visited_groups += 1) {
                if (group_idx >= group_limit) {
                    try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_idx } });
                    break;
                }
                if (owned_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .block_double_owned = .{ .block = group_idx } });
                }
                owned_groups_debug.set(group_idx);
                if (free_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = group_idx } });
                }
                if (retired_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .retired_block_reachable = .{ .block = group_idx, .node = node_id } });
                }
                group_idx = page_ops.groupAtConst(graph, group_idx).next;
            }
        }
        if (adjacency.group_count_rev > 0) {
            var group_idx = adjacency.first_group_rev;
            var visited_groups: u32 = 0;
            while (group_idx != constants.END_OF_CHAIN and visited_groups < adjacency.group_count_rev) : (visited_groups += 1) {
                if (group_idx >= group_limit) {
                    try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_idx } });
                    break;
                }
                if (owned_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .block_double_owned = .{ .block = group_idx } });
                }
                owned_groups_debug.set(group_idx);
                if (free_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = group_idx } });
                }
                if (retired_groups_debug.isSet(group_idx)) {
                    try violations.append(allocator, .{ .retired_block_reachable = .{ .block = group_idx, .node = node_id } });
                }
                group_idx = page_ops.groupAtConst(graph, group_idx).next;
            }
        }

        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_forward_blocks, &free_forward_blocks, &retired_forward_blocks, node_id, forward_blocks.items, .fwd);
        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_reverse_blocks, &free_reverse_blocks, &retired_reverse_blocks, node_id, reverse_blocks.items, .rev);
        try appendForwardConsistencyViolations(graph, allocator, &violations, node_id, forward_blocks.items);
        try appendReverseConsistencyViolations(graph, allocator, &violations, node_id, reverse_blocks.items);

        if (!adjacency.flags.removed) {
            for (forward_blocks.items) |block| {
                total_visible_fwd += countVisibleEntriesInBlock(graph, block.block_index, .fwd);
            }
            for (reverse_blocks.items) |block| {
                total_visible_rev += countVisibleEntriesInBlock(graph, block.block_index, .rev);
            }
        }

        // RFC §2.5: degree cache consistency. Removed nodes are exempt:
        // their reverse side may retain residual tomstoned structure that
        // does not contribute to the public logical degree.
        const node_buffer = page_ops.nodeAtConst(graph, .{ .index = node_id });
        if (!adjacency.flags.removed) {
            const cached_fwd: usize = node_buffer.degree_fwd;
            const cached_rev: usize = node_buffer.degree_rev;
            const live_fwd: usize = @intCast(sumVisibleAdjacency(graph, adjacency, .fwd));
            if (live_fwd < constants.DEGREE_OVERFLOW and cached_fwd != live_fwd) {
                try violations.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(live_fwd), .actual = @intCast(cached_fwd) } });
            }
            const live_rev: usize = @intCast(sumVisibleAdjacency(graph, adjacency, .rev));
            if (live_rev < constants.DEGREE_OVERFLOW and cached_rev != live_rev) {
                try violations.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(live_rev), .actual = @intCast(cached_rev) } });
            }
            // RFC §6.3, §A.26: live predecessor with forward tombstone MUST
            // have needs_repair_fwd set.
            if (!adjacency.flags.needs_repair_fwd and forwardHasTombstone(graph, adjacency)) {
                try violations.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = 0, .actual = 1 } });
            }
        }

        if (adjacency.flags.removed and (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or node_buffer.degree_fwd != 0)) {
            try violations.append(allocator, .{ .removed_node_has_outgoing = .{ .node = node_id } });
        }
        if (adjacency.flags.removed and (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev)) {
            try violations.append(allocator, .{ .removed_node_marked_for_repair = .{ .node = node_id } });
        }

        // RFC §3.2: at most MAX_GROUPS_PER_NODE runs without repair.
        // Removed nodes are exempt from layout debt checks: their reverse side
        // may retain grouped tombstones until compaction (RFC §6.3).
        if (!adjacency.flags.removed) {
            if (adjacency.group_count_fwd > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_fwd) {
                try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
            }
            if (adjacency.group_count_rev > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_rev) {
                try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
            }
            try appendLayoutDebtViolations(graph, allocator, &violations, node_id, adjacency, .fwd);
            try appendLayoutDebtViolations(graph, allocator, &violations, node_id, adjacency, .rev);
        }
    }

    try appendRepairDebtViolations(graph, allocator, &violations);

    {
        const fwd_limit = @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire);
        for (0..fwd_limit) |block_index| {
            if (!owned_forward_blocks.isSet(block_index) and
                !free_forward_blocks.isSet(block_index) and
                !retired_forward_blocks.isSet(block_index))
            {
                try violations.append(allocator, .{ .unreachable_forward_block = .{ .block = @intCast(block_index) } });
            }
        }
    }
    {
        const rev_limit = @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire);
        for (0..rev_limit) |block_index| {
            if (!owned_reverse_blocks.isSet(block_index) and
                !free_reverse_blocks.isSet(block_index) and
                !retired_reverse_blocks.isSet(block_index))
            {
                try violations.append(allocator, .{ .unreachable_reverse_block = .{ .block = @intCast(block_index) } });
            }
        }
    }
    {
        for (0..group_limit) |group_index| {
            if (!owned_groups_debug.isSet(group_index) and
                !free_groups_debug.isSet(group_index) and
                !retired_groups_debug.isSet(group_index))
            {
                try violations.append(allocator, .{ .unreachable_group = .{ .group = @intCast(group_index) } });
            }
        }
    }

    if (total_visible_fwd != total_visible_rev) {
        try violations.append(allocator, .{ .forward_reverse_count_mismatch = .{ .forward_total = total_visible_fwd, .reverse_total = total_visible_rev } });
    }
    if (total_visible_fwd != graph.edge_count.load(.acquire)) {
        try violations.append(allocator, .{ .edge_count_mismatch = .{ .expected = total_visible_fwd, .actual = graph.edge_count.load(.acquire) } });
    }

    return violations.toOwnedSlice(allocator);
}
