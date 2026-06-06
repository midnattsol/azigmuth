//! Adjacency chain manipulation — groups, block traversal, and edge search.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const node_validity = @import("core/node_validity.zig");

pub const AdjSide = enum { fwd, rev };

fn allocatedBlockCount(graph: *const graph_core.GraphCore, comptime side: AdjSide) u32 {
    return switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };
}

pub fn validateSideAdjLayoutForSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: AdjSide,
) !void {
    const block_limit = allocatedBlockCount(graph, side);
    if (side_adj.block_count == 0) {
        if (side_adj.group_count != 0) return error.CorruptGraph;
        return;
    }

    if (side_adj.group_count == 0) {
        if (side_adj.first_block >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, side_adj.first_block, side_adj.block_count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        return;
    }

    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    var total_blocks: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited >= side_adj.group_count or visited >= graph.group_count) return error.CorruptGraph;
        visited += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        if (group.start >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, group.start, group.count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        total_blocks += group.count;
        group_index = group.next;
    }

    if (visited != side_adj.group_count) return error.CorruptGraph;
    if (total_blocks != side_adj.block_count) return error.CorruptGraph;
}

pub fn validateSideAdjLayout(graph: *const graph_core.GraphCore, side_adj: types.SideAdj) !void {
    if (side_adj.block_count == 0) {
        if (side_adj.group_count != 0) return error.CorruptGraph;
        return;
    }
    if (side_adj.group_count == 0) return;

    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    var total_blocks: u32 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited >= side_adj.group_count or visited >= graph.group_count) return error.CorruptGraph;
        visited += 1;

        const group = page_ops.groupAtConst(graph, group_index);
        if (group.count == 0) return error.CorruptGraph;
        total_blocks += group.count;
        group_index = group.next;
    }

    if (visited != side_adj.group_count) return error.CorruptGraph;
    if (total_blocks != side_adj.block_count) return error.CorruptGraph;
}

pub fn validateNodeAdjLayout(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, comptime side: AdjSide) !void {
    const side_adj = switch (side) {
        .fwd => types.SideAdj{
            .first_block = node_adj.first_block_fwd,
            .block_count = node_adj.block_count_fwd,
            .group_count = node_adj.group_count_fwd,
            .first_group = node_adj.first_group_fwd,
        },
        .rev => types.SideAdj{
            .first_block = node_adj.first_block_rev,
            .block_count = node_adj.block_count_rev,
            .group_count = node_adj.group_count_rev,
            .first_group = node_adj.first_group_rev,
        },
    };
    try validateSideAdjLayoutForSide(graph, side_adj, side);
}

fn groupCount(node_adj: *const types.NodeAdj, comptime dir: AdjSide) u16 {
    return if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
}

fn firstGroup(node_adj: *const types.NodeAdj, comptime dir: AdjSide) u32 {
    return if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
}

fn setFirstGroup(node_adj: *types.NodeAdj, comptime dir: AdjSide, group_index: u32) void {
    if (dir == .fwd) {
        node_adj.first_group_fwd = group_index;
    } else {
        node_adj.first_group_rev = group_index;
    }
}

// ── SideAdj helpers (per-side publication model) ──────────────────────

pub fn tailBlockIndexSideChecked(graph: *graph_core.GraphCore, side_adj: *const types.SideAdj) !?u32 {
    if (side_adj.block_count == 0) return null;
    if (side_adj.group_count == 0) return side_adj.first_block + side_adj.block_count - 1;

    try validateSideAdjLayout(graph, side_adj.*);

    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    while (visited < side_adj.group_count) : (visited += 1) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) return group.start + group.count - 1;
        group_index = group.next;
    }
    return null;
}

pub fn tailBlockIndexSide(graph: *graph_core.GraphCore, side_adj: *const types.SideAdj) ?u32 {
    return tailBlockIndexSideChecked(graph, side_adj) catch null;
}

pub fn extendTailGroupSide(graph: *graph_core.GraphCore, side_adj: *types.SideAdj) void {
    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    while (visited < side_adj.group_count) : (visited += 1) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) {
            group.count += 1;
            break;
        }
        group_index = group.next;
    }
}

pub fn hasEdgeInSideAdjChecked(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, target: u32) !bool {
    if (side_adj.block_count == 0) return false;
    try validateSideAdjLayoutForSide(graph, side_adj, .fwd);
    if (side_adj.group_count == 0) {
        return hasEdgeInForwardRun(graph, side_adj.first_block, side_adj.block_count, target);
    }

    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    while (visited < side_adj.group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_index);
        if (hasEdgeInForwardRun(graph, group.start, group.count, target)) return true;
        group_index = group.next;
    }
    return false;
}

pub fn hasEdgeInSideAdj(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, target: u32) bool {
    return hasEdgeInSideAdjChecked(graph, side_adj, target) catch false;
}

// ── Shape inspection, lookup helpers ────────────────────────────────────

pub fn searchInBlock(comptime BlockType: type, block: *const BlockType, target: u32) ?u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    if (live == 0) return null;

    const first = if (BlockType == types.EdgeBlockFwd) block.edges[0].destination else block.sources[0];
    if (target < first or target > (if (BlockType == types.EdgeBlockFwd) block.edges[live - 1].destination else block.sources[live - 1])) return null;

    var low: u7 = 0;
    var high: u7 = @intCast(live);
    while (low < high) {
        const probe: u7 = low + (high - low) / 2;
        const probe_val = if (BlockType == types.EdgeBlockFwd) block.edges[probe].destination else block.sources[probe];
        if (probe_val < target) {
            low = probe + 1;
        } else if (probe_val == target) {
            return probe;
        } else {
            high = probe;
        }
    }
    return null;
}

fn forwardRunRangesMonotonic(graph: *const graph_core.GraphCore, start: u32, count: u16) bool {
    var prev_last: ?u32 = null;
    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        const live = @popCount(block.mask);
        if (live == 0) continue;

        const first_edge = block.edges[0].destination;
        const last_edge = block.edges[live - 1].destination;
        if (prev_last) |previous| {
            if (previous > first_edge) return false;
        }
        prev_last = last_edge;
    }
    return true;
}

fn hasEdgeInForwardRun(graph: *const graph_core.GraphCore, start: u32, count: u16, target: u32) bool {
    var low: u32 = 0;
    var high: u32 = count;
    var hit_empty = false;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block = page_ops.edgeBlockAtConst(graph, start + mid, .fwd);
        const live = @popCount(block.mask);
        if (live == 0) {
            hit_empty = true;
            break;
        }

        const first_edge = block.edges[0].destination;
        const last_edge = block.edges[live - 1].destination;
        if (target < first_edge) {
            high = mid;
        } else if (target > last_edge) {
            low = mid + 1;
        } else {
            return searchInBlock(types.EdgeBlockFwd, block, target) != null;
        }
    }

    if (!hit_empty and forwardRunRangesMonotonic(graph, start, count)) return false;

    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
    }
    return false;
}

fn forwardAdjRangesMonotonic(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
) bool {
    if (group_count == 0) return forwardRunRangesMonotonic(graph, first_block, block_count);

    var prev_last: ?u32 = null;
    var group_index = first_group;
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            if (live == 0) continue;

            const first_edge = block.edges[0].destination;
            const last_edge = block.edges[live - 1].destination;
            if (prev_last) |previous| {
                if (previous > first_edge) return false;
            }
            prev_last = last_edge;
        }
        group_index = group.next;
    }
    return true;
}

pub fn hasEdgeInAdjChecked(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) !bool {
    const block_count = node_adj.block_count_fwd;
    if (block_count == 0) return false;
    try validateNodeAdjLayout(graph, node_adj, .fwd);

    if (node_adj.group_count_fwd == 0) {
        return hasEdgeInForwardRun(graph, node_adj.first_block_fwd, block_count, target);
    }

    var group_index = node_adj.first_group_fwd;
    var visited: u16 = 0;
    while (visited < node_adj.group_count_fwd) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_index);
        if (hasEdgeInForwardRun(graph, group.start, group.count, target)) return true;
        group_index = group.next;
    }
    return false;
}

pub fn hasEdgeInAdj(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) bool {
    return hasEdgeInAdjChecked(graph, node_adj, target) catch false;
}

// ── Multigraph helpers ─────────────────────────────────────────────────

/// Counts how many times `target` appears as a destination in forward blocks.
pub fn countForwardInBlock(block: *const types.EdgeBlockFwd, target: u32) u32 {
    const live = @popCount(block.mask);
    if (live == 0) return 0;
    if (target < block.edges[0].destination) return 0;
    if (target > block.edges[live - 1].destination) return 0;

    var count: u32 = 0;
    for (0..live) |slot| {
        if (block.edges[slot].destination == target) {
            count += 1;
        } else if (block.edges[slot].destination > target and count > 0) {
            break;
        }
    }
    return count;
}

/// Counts forward edges to `destination_index` across an adjacency descriptor.
pub fn countForwardDestinationMatchesChecked(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    destination_index: u32,
) !u32 {
    if (block_count == 0) return 0;

    try validateSideAdjLayoutForSide(graph, .{
        .first_block = first_block,
        .block_count = block_count,
        .group_count = group_count,
        .first_group = first_group,
    }, .fwd);

    var total: u32 = 0;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            total += countForwardInBlock(block, destination_index);
        }
        return total;
    }

    var group_idx = first_group;
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            total += countForwardInBlock(block, destination_index);
        }
        group_idx = group.next;
    }
    return total;
}

pub fn countForwardDestinationMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    destination_index: u32,
) u32 {
    return countForwardDestinationMatchesChecked(
        graph,
        first_block,
        block_count,
        group_count,
        first_group,
        destination_index,
    ) catch 0;
}

pub const ForwardBlockSlot = struct {
    block_idx: u32,
    slot: u7,
};

fn lowerBoundDestination(block: *const types.EdgeBlockFwd, target: u32) u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    var low: u7 = 0;
    var high: u7 = live;
    while (low < high) {
        const mid: u7 = low + (high - low) / 2;
        if (block.edges[mid].destination < target) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn upperBoundDestination(block: *const types.EdgeBlockFwd, target: u32) u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    var low: u7 = 0;
    var high: u7 = live;
    while (low < high) {
        const mid: u7 = low + (high - low) / 2;
        if (block.edges[mid].destination <= target) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn searchForwardBlockSlotById(
    block: *const types.EdgeBlockFwd,
    id_block: *const types.EdgeBlockFwdIds,
    destination_index: u32,
    edge_id: u32,
) ?u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    if (live == 0) return null;
    if (destination_index < block.edges[0].destination) return null;
    if (destination_index > block.edges[live - 1].destination) return null;

    const start = lowerBoundDestination(block, destination_index);
    if (start >= live or block.edges[start].destination != destination_index) return null;
    const end = upperBoundDestination(block, destination_index);

    var low: u7 = start;
    var high: u7 = end;
    while (low < high) {
        const mid: u7 = low + (high - low) / 2;
        const probe_id = id_block.ids[mid];
        if (probe_id < edge_id) {
            low = mid + 1;
        } else if (probe_id > edge_id) {
            high = mid;
        } else {
            return mid;
        }
    }
    return null;
}

pub fn findForwardSlotByIdInRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    destination_index: u32,
    edge_id: u32,
) ?ForwardBlockSlot {
    if (count == 0) return null;

    var low: u32 = 0;
    var high: u32 = count;
    var hit_empty = false;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block_idx = start + mid;
        const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
        const live = @popCount(block.mask);
        if (live == 0) {
            hit_empty = true;
            break;
        }

        const first_edge = block.edges[0].destination;
        const last_edge = block.edges[live - 1].destination;
        if (destination_index < first_edge) {
            high = mid;
            continue;
        }
        if (destination_index > last_edge) {
            low = mid + 1;
            continue;
        }

        const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
        if (searchForwardBlockSlotById(block, id_block, destination_index, edge_id)) |slot| {
            return .{ .block_idx = block_idx, .slot = slot };
        }

        var left = mid;
        while (left > 0) {
            const left_block_idx = start + left - 1;
            const left_block = page_ops.edgeBlockAtConst(graph, left_block_idx, .fwd);
            const left_live = @popCount(left_block.mask);
            if (left_live == 0) break;
            if (destination_index < left_block.edges[0].destination or destination_index > left_block.edges[left_live - 1].destination) break;
            const left_ids = page_ops.edgeBlockFwdIdsAtConst(graph, left_block_idx);
            if (searchForwardBlockSlotById(left_block, left_ids, destination_index, edge_id)) |slot| {
                return .{ .block_idx = left_block_idx, .slot = slot };
            }
            left -= 1;
        }

        var right = mid + 1;
        while (right < count) : (right += 1) {
            const right_block_idx = start + right;
            const right_block = page_ops.edgeBlockAtConst(graph, right_block_idx, .fwd);
            const right_live = @popCount(right_block.mask);
            if (right_live == 0) break;
            if (destination_index < right_block.edges[0].destination or destination_index > right_block.edges[right_live - 1].destination) break;
            const right_ids = page_ops.edgeBlockFwdIdsAtConst(graph, right_block_idx);
            if (searchForwardBlockSlotById(right_block, right_ids, destination_index, edge_id)) |slot| {
                return .{ .block_idx = right_block_idx, .slot = slot };
            }
        }

        if (!hit_empty and forwardRunRangesMonotonic(graph, start, count)) return null;
        break;
    }

    for (start..start + count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
        const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
        if (searchForwardBlockSlotById(block, id_block, destination_index, edge_id)) |slot| {
            return .{ .block_idx = block_idx, .slot = slot };
        }
    }

    return null;
}


/// Searches a forward block for a specific (destination, edge_id) pair.
/// Returns the slot index or null.
pub fn searchForwardBlockById(
    block: *const types.EdgeBlockFwd,
    id_block: *const types.EdgeBlockFwdIds,
    destination_index: u32,
    edge_id: u32,
) ?u7 {
    return searchForwardBlockSlotById(block, id_block, destination_index, edge_id);
}
pub fn publishedNodeAdj(graph: *const graph_core.GraphCore, node: types.NodeId) !types.NodeAdj {
    try node_validity.ensureLiveNode(graph, node);
    const node_buffer = page_ops.nodeAtConst(graph, node);
    return node_buffer.publishedAdj();
}
