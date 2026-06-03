const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");
pub fn runContainsTarget(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: common.Side,
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
pub fn findSlotInRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime BlockType: type,
    comptime side: common.Side,
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

pub fn adjacencyContains(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, target: u32, comptime side: common.Side) bool {
    const count = common.blockCount(adjacency, side);
    if (count == 0) return false;

    if (common.groupCount(adjacency, side) == 0) {
        return runContainsTarget(graph, common.firstBlock(adjacency, side), count, target, side);
    }

    var group_index = common.firstGroup(adjacency, side);
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

pub fn appendForwardConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    source_node: u32,
    blocks: []const common.TraversedBlock,
) !void {
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .fwd)) continue;

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

pub fn appendReverseConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    destination_node: u32,
    blocks: []const common.TraversedBlock,
) !void {
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .rev)) continue;

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

pub fn appendRepairDebtViolations(
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

pub fn appendLayoutDebtViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    comptime side: common.Side,
) !void {
    const groups = common.groupCount(adjacency, side);
    if (groups == 0) return;

    var group_index = common.firstGroup(adjacency, side);
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
        if (!is_last_group and group.count < 4 and !common.needsRepairFlag(adjacency, side)) {
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

    if (chain_is_contiguous and !common.needsRepairFlag(adjacency, side)) {
        try violations.append(allocator, .{ .grouped_layout_needs_canonicalization = .{
            .node = node_id,
            .first_group = common.firstGroup(adjacency, side),
        } });
    }
}

pub fn validateForwardConsistencyFast(graph: *const graph_core.GraphCore, source_node: u32, adjacency: types.NodeAdj) !void {
    if (common.blockCount(adjacency, .fwd) == 0) return;

    if (common.groupCount(adjacency, .fwd) == 0) {
        return validateForwardConsistencyInContiguousBlocks(graph, source_node, common.firstBlock(adjacency, .fwd), common.blockCount(adjacency, .fwd));
    }

    var group_index = common.firstGroup(adjacency, .fwd);
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

pub fn validateForwardConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, start: u32, count: u16) !void {
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

pub fn validateReverseConsistencyFast(graph: *const graph_core.GraphCore, destination_node: u32, adjacency: types.NodeAdj) !void {
    if (common.blockCount(adjacency, .rev) == 0) return;

    if (common.groupCount(adjacency, .rev) == 0) {
        return validateReverseConsistencyInContiguousBlocks(graph, destination_node, common.firstBlock(adjacency, .rev), common.blockCount(adjacency, .rev));
    }

    var group_index = common.firstGroup(adjacency, .rev);
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

pub fn validateReverseConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, destination_node: u32, start: u32, count: u16) !void {
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
