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

    const mask = blockMask(graph, block_index, side);
    const live_count = @popCount(mask);
    if (mask != constants.denseMask(@intCast(live_count))) return error.CorruptGraph;

    for (0..live_count) |slot| {
        const key = blockKey(graph, block_index, slot, side);
        if (key >= graph.node_count) return error.CorruptGraph;
        if (slot > 0 and key <= blockKey(graph, block_index, slot - 1, side)) return error.CorruptGraph;
    }

    return live_count;
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

    var visited_groups = try std.DynamicBitSetUnmanaged.initEmpty(allocator, graph.group_count);
    defer visited_groups.deinit(allocator);

    var block_owner_by_group = std.AutoHashMap(u32, u32).init(allocator);
    defer block_owner_by_group.deinit();

    var group_index = firstGroup(adjacency, side);
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return;

        if (visited_groups.isSet(group_index)) {
            try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_index } });
            return;
        }
        visited_groups.set(group_index);

        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index_usize| {
            const block_index: u32 = @intCast(block_index_usize);
            if (block_owner_by_group.get(block_index)) |owner_group| {
                try violations.append(allocator, .{ .blockgroup_overlap = .{ .node = node_id, .group_a = owner_group, .group_b = group_index } });
            } else {
                try block_owner_by_group.put(block_index, group_index);
            }
            try blocks.append(allocator, .{ .block_index = block_index });
        }

        group_index = group.next;
    }
}

fn freeListContains(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) bool {
    const free_blocks = switch (side) {
        .fwd => graph.free_blocks_fwd.items,
        .rev => graph.free_blocks_rev.items,
    };

    for (free_blocks) |free_block| {
        if (free_block == block_index) return true;
    }
    return false;
}

fn retiredListContains(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Side) bool {
    const retired_blocks = switch (side) {
        .fwd => graph.retired_blocks_fwd.items,
        .rev => graph.retired_blocks_rev.items,
    };

    for (retired_blocks) |retired_block| {
        if (retired_block.block == block_index) return true;
    }
    return false;
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

        if (freeListContains(graph, block_index, side)) {
            try violations.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = block_index } });
        }

        if (retiredListContains(graph, block_index, side)) {
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

fn blockContains(graph: *const graph_core.GraphCore, block_index: u32, target: u32, comptime side: Side) bool {
    if (!blockExists(graph, block_index, side)) return false;

    const live_count = @popCount(blockMask(graph, block_index, side));
    for (0..live_count) |slot| {
        if (blockKey(graph, block_index, slot, side) == target) return true;
    }
    return false;
}

fn contiguousBlocksContain(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: Side,
) bool {
    for (start..start + count) |block_index| {
        if (blockContains(graph, @intCast(block_index), target, side)) return true;
    }
    return false;
}

fn groupChainContains(graph: *const graph_core.GraphCore, first_group: u32, target: u32, comptime side: Side) bool {
    var group_index = first_group;
    var visited_groups: u32 = 0;

    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return false;
        if (visited_groups > graph.group_count) return false;
        visited_groups += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (contiguousBlocksContain(graph, group.start, group.count, target, side)) return true;
        group_index = group.next;
    }

    return false;
}

fn adjacencyContains(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, target: u32, comptime side: Side) bool {
    if (blockCount(adjacency, side) == 0) return false;

    if (groupCount(adjacency, side) == 0) {
        return contiguousBlocksContain(graph, firstBlock(adjacency, side), blockCount(adjacency, side), target, side);
    }

    return groupChainContains(graph, firstGroup(adjacency, side), target, side);
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
        try validateReverseConsistencyFast(graph, node_id, adjacency);
    }

    if (total_forward != total_reverse) return error.CorruptGraph;
    if (total_forward != graph.edge_count.load(.acquire)) return error.CorruptGraph;
}

pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    const reader_token = readerEnter(graph);
    defer readerExit(graph, reader_token);

    var violations: std.ArrayList(types.Violation) = .empty;
    var total: u64 = 0;

    var owned_forward_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire));
    defer owned_forward_blocks.deinit(allocator);
    var owned_reverse_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire));
    defer owned_reverse_blocks.deinit(allocator);

    for (0..graph.node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        var forward_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer forward_blocks.deinit(allocator);
        var reverse_blocks: std.ArrayList(TraversedBlock) = .empty;
        defer reverse_blocks.deinit(allocator);

        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &forward_blocks, .fwd);
        try collectAdjacencyBlocks(graph, allocator, &violations, node_id, adjacency, &reverse_blocks, .rev);

        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_forward_blocks, node_id, forward_blocks.items, .fwd);
        try appendOwnershipAndShapeViolations(graph, allocator, &violations, &owned_reverse_blocks, node_id, reverse_blocks.items, .rev);
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
