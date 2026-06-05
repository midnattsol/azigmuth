//! Adjacency chain manipulation — groups, block traversal, and edge search.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const node_validity = @import("core/node_validity.zig");

pub const AdjSide = enum { fwd, rev };

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

pub fn tailBlockIndexSide(graph: *graph_core.GraphCore, side_adj: *const types.SideAdj) ?u32 {
    if (side_adj.block_count == 0) return null;
    if (side_adj.group_count == 0) return side_adj.first_block + side_adj.block_count - 1;

    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    while (visited < side_adj.group_count) : (visited += 1) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) return group.start + group.count - 1;
        group_index = group.next;
    }
    return null;
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

pub fn hasEdgeInSideAdj(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, target: u32) bool {
    if (side_adj.block_count == 0) return false;
    if (side_adj.group_count == 0) {
        var low: u32 = 0;
        var high: u32 = side_adj.block_count;
        while (low < high) {
            const mid: u32 = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, side_adj.first_block + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first_edge = block.edges[0].destination;
            const last_edge = block.edges[live - 1].destination;
            if (target < first_edge) {
                high = mid;
            } else if (target > last_edge) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (side_adj.first_block..side_adj.first_block + side_adj.block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        return false;
    }
    var group_index = side_adj.first_group;
    var visited: u16 = 0;
    while (visited < side_adj.group_count) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_index);
        var low: u32 = 0;
        var high: u32 = group.count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, group.start + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first = block.edges[0].destination;
            const last = block.edges[live - 1].destination;
            if (target < first) {
                high = mid;
            } else if (target > last) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        if (group.next == constants.END_OF_CHAIN) return false;
        group_index = group.next;
    }
    return false;
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

pub fn hasEdgeInAdj(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) bool {
    const block_count = node_adj.block_count_fwd;
    if (block_count == 0) return false;

    if (node_adj.group_count_fwd == 0) {
        const first_block = node_adj.first_block_fwd;
        var low: u32 = 0;
        var high: u32 = block_count;
        while (low < high) {
            const mid: u32 = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, first_block + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first_edge = block.edges[0].destination;
            const last_edge = block.edges[live - 1].destination;
            if (target < first_edge) {
                high = mid;
            } else if (target > last_edge) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        return false;
    }

    var group_index = node_adj.first_group_fwd;
    var visited: u16 = 0;
    while (visited < node_adj.group_count_fwd) : (visited += 1) {
        const group = page_ops.groupAtConst(graph, group_index);
        var low: u32 = 0;
        var high: u32 = group.count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, group.start + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first = block.edges[0].destination;
            const last = block.edges[live - 1].destination;
            if (target < first) {
                high = mid;
            } else if (target > last) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        if (group.next == constants.END_OF_CHAIN) return false;
        group_index = group.next;
    }
    return false;
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
pub fn countForwardDestinationMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    destination_index: u32,
) u32 {
    if (block_count == 0) return 0;

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
        if (group_idx == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            total += countForwardInBlock(block, destination_index);
        }
        group_idx = group.next;
    }
    return total;
}


/// Searches a forward block for a specific (destination, edge_id) pair.
/// Returns the slot index or null.
pub fn searchForwardBlockById(
    block: *const types.EdgeBlockFwd,
    id_block: *const types.EdgeBlockFwdIds,
    destination_index: u32,
    edge_id: u32,
) ?u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    if (live == 0) return null;
    if (destination_index < block.edges[0].destination) return null;
    if (destination_index > block.edges[live - 1].destination) return null;
    for (0..live) |slot| {
        if (block.edges[slot].destination == destination_index and id_block.ids[slot] == edge_id) {
            return @intCast(slot);
        }
    }
    return null;
}
pub fn publishedNodeAdj(graph: *const graph_core.GraphCore, node: types.NodeId) !types.NodeAdj {
    try node_validity.ensureLiveNode(graph, node);
    const node_buffer = page_ops.nodeAtConst(graph, node);
    return node_buffer.publishedAdj();
}
