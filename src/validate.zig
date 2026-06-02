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

const Side = enum { fwd, rev };

const TraversedBlock = struct {
    block_index: u32,
};

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

    if (side == .fwd) {
        const block = page_ops.edgeBlockAtConst(graph, block_index, .fwd);
        const live_count = @popCount(block.mask);
        if (block.mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;
        var prev: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.edges[slot].destination;
            if (key >= graph.node_count) return error.CorruptGraph;
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
            if (key >= graph.node_count) return error.CorruptGraph;
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
        if (key >= graph.node_count) {
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
        if (group_index >= graph.group_count) return;
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
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, allocatedBlockCount(graph, side));
    const free_blocks = switch (side) {
        .fwd => graph.free_blocks_fwd.items,
        .rev => graph.free_blocks_rev.items,
    };
    for (free_blocks) |free_block| {
        if (free_block < allocatedBlockCount(graph, side)) set.set(@intCast(free_block));
    }
    return set;
}

fn buildRetiredBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: Side,
) !std.DynamicBitSetUnmanaged {
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, allocatedBlockCount(graph, side));
    const retired_blocks = switch (side) {
        .fwd => graph.retired_blocks_fwd.items,
        .rev => graph.retired_blocks_rev.items,
    };
    for (retired_blocks) |retired_block| {
        if (retired_block.block < allocatedBlockCount(graph, side)) set.set(@intCast(retired_block.block));
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
            if (destination_node >= graph.node_count) continue;

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
            if (source_node >= graph.node_count) continue;

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
    for (graph.repair_fwd.items) |node_index| {
        if (node_index >= graph.node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_index } });
        }
    }
    for (graph.repair_rev.items) |node_index| {
        if (node_index >= graph.node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_index } });
        }
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
            if (destination_node >= graph.node_count) return error.CorruptGraph;

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
            if (source_node >= graph.node_count) return error.CorruptGraph;

            const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
            if (!adjacencyContains(graph, source_adjacency, destination_node, .fwd)) return error.CorruptGraph;
        }
    }
}

pub fn validate(graph: *const graph_core.GraphCore) !void {
    const reader_token = readerEnter(graph);
    defer readerExit(graph, reader_token);

    var total_forward: u64 = 0;
    var total_reverse: u64 = 0;

    for (0..graph.node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        total_forward += try validateAdjacencyBlocksFast(graph, adjacency, .fwd);
        total_reverse += try validateAdjacencyBlocksFast(graph, adjacency, .rev);
        try validateOccupancyFast(graph, adjacency, .fwd);
        try validateOccupancyFast(graph, adjacency, .rev);
        try validateForwardConsistencyFast(graph, node_id, adjacency);
    }

    if (total_forward != total_reverse) return error.CorruptGraph;
    if (total_forward != graph.edge_count.load(.acquire)) return error.CorruptGraph;
}

pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    const reader_token = readerEnter(graph);
    defer readerExit(graph, reader_token);

    var violations: std.ArrayList(types.Violation) = .empty;
    errdefer violations.deinit(allocator);
    var total: u64 = 0;

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

    for (0..graph.node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        var forward_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer forward_blocks.deinit(allocator);
        var reverse_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer reverse_blocks.deinit(allocator);

        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &forward_blocks, .fwd);
        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &reverse_blocks, .rev);

        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_forward_blocks, &free_forward_blocks, &retired_forward_blocks, node_id, forward_blocks.items, .fwd);
        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_reverse_blocks, &free_reverse_blocks, &retired_reverse_blocks, node_id, reverse_blocks.items, .rev);
        try appendForwardConsistencyViolations(graph, allocator, &violations, node_id, forward_blocks.items);
        try appendReverseConsistencyViolations(graph, allocator, &violations, node_id, reverse_blocks.items);

        for (forward_blocks.items) |block| {
            total += sumBlockLive(graph, block.block_index, .fwd);
        }
    }

    try appendRepairDebtViolations(graph, allocator, &violations);

    if (total != graph.edge_count.load(.acquire)) {
        try violations.append(allocator, .{ .edge_count_mismatch = .{ .expected = total, .actual = graph.edge_count.load(.acquire) } });
    }

    return violations.toOwnedSlice(allocator);
}
