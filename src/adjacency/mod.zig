//! Adjacency chain manipulation — segments, block traversal, and edge search.

const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const node_access = @import("../core/node_access.zig");
const tiny_config = @import("../core/tiny_config.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_adjacency_buffers = @import("../storage/node/adjacency_buffers.zig");
const node_tiny = @import("../storage/node/tiny.zig");
const node_validity = @import("../core/node_validity.zig");

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
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        if (side_adj.segment_count != 0 or side_adj.first_segment != 0) return error.CorruptGraph;
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
        const max_count: u16 = switch (side) {
            .fwd => if (graph.multigraph_enabled) tiny_config.TINY_FWD_CAP_MULTI else tiny_config.TINY_FWD_CAP_SIMPLE,
            .rev => tiny_config.TINY_REV_CAP,
        };
        if (count > max_count) return error.CorruptGraph;
        switch (side) {
            .fwd => if (side_adj.first_block >= graph.loadTinyFwdCount()) return error.CorruptGraph,
            .rev => if (side_adj.first_block >= graph.loadTinyRevCount()) return error.CorruptGraph,
        }
        return;
    }

    const block_limit = allocatedBlockCount(graph, side);
    if (side_adj.block_count == 0) {
        if (side_adj.segment_count != 0) return error.CorruptGraph;
        return;
    }

    if (side_adj.segment_count == 0) {
        if (side_adj.first_block >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, side_adj.first_block, side_adj.block_count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        return;
    }

    var total_blocks: u32 = 0;
    if (side_adj.first_segment >= graph.loadSegmentCount()) return error.CorruptGraph;
    const end_segment = std.math.add(u32, side_adj.first_segment, side_adj.segment_count) catch return error.CorruptGraph;
    if (end_segment > graph.loadSegmentCount()) return error.CorruptGraph;
    for (side_adj.first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (segment.count == 0) return error.CorruptGraph;
        if (segment.start >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, segment.start, segment.count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        total_blocks += segment.count;
    }

    if (total_blocks != side_adj.block_count) return error.CorruptGraph;
}

pub fn validateSideAdjLayout(graph: *const graph_core.GraphCore, side_adj: types.SideAdj) !void {
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        if (side_adj.segment_count != 0 or side_adj.first_segment != 0) return error.CorruptGraph;
        return;
    }
    if (side_adj.block_count == 0) {
        if (side_adj.segment_count != 0) return error.CorruptGraph;
        return;
    }
    if (side_adj.segment_count == 0) return;

    var total_blocks: u32 = 0;
    if (side_adj.first_segment >= graph.loadSegmentCount()) return error.CorruptGraph;
    const end_segment = std.math.add(u32, side_adj.first_segment, side_adj.segment_count) catch return error.CorruptGraph;
    if (end_segment > graph.loadSegmentCount()) return error.CorruptGraph;
    for (side_adj.first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (segment.count == 0) return error.CorruptGraph;
        total_blocks += segment.count;
    }

    if (total_blocks != side_adj.block_count) return error.CorruptGraph;
}

pub fn sideAdjOfNode(node_adj: types.NodeAdj, comptime side: AdjSide) types.SideAdj {
    return switch (side) {
        .fwd => .{
            .first_block = node_adj.first_block_fwd,
            .block_count = node_adj.block_count_fwd,
            .segment_count = node_adj.segment_count_fwd,
            .first_segment = node_adj.first_segment_fwd,
        },
        .rev => .{
            .first_block = node_adj.first_block_rev,
            .block_count = node_adj.block_count_rev,
            .segment_count = node_adj.segment_count_rev,
            .first_segment = node_adj.first_segment_rev,
        },
    };
}

pub fn validateNodeAdjLayout(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, comptime side: AdjSide) !void {
    try validateSideAdjLayoutForSide(graph, sideAdjOfNode(node_adj, side), side);
}

// ── SideAdj helpers (per-side publication model) ──────────────────────

pub fn tailBlockIndexSideChecked(graph: *graph_core.GraphCore, side_adj: *const types.SideAdj) !?u32 {
    if (side_adj.block_count == 0) return null;
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(side_adj)) return null;
    if (side_adj.segment_count == 0) return side_adj.first_block + side_adj.block_count - 1;

    try validateSideAdjLayout(graph, side_adj.*);

    const tail_segment = page_ops.edgeBlockSegmentAt(graph, side_adj.first_segment + side_adj.segment_count - 1);
    return tail_segment.start + tail_segment.count - 1;
}

pub fn tailBlockIndexSide(graph: *graph_core.GraphCore, side_adj: *const types.SideAdj) ?u32 {
    return tailBlockIndexSideChecked(graph, side_adj) catch null;
}

pub fn hasEdgeInSideAdjChecked(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, target: u32, globally_sorted: bool) !bool {
    if (side_adj.block_count == 0) return false;
    try validateSideAdjLayoutForSide(graph, side_adj, .fwd);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const slot = page_ops.tinySlotAtConst(graph, side_adj.first_block, .fwd);
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            if (slot.entries[entry_idx].destination == target) return true;
        }
        return false;
    }
    if (side_adj.segment_count == 0) {
        return hasEdgeInForwardRun(graph, side_adj.first_block, side_adj.block_count, target, globally_sorted);
    }

    const end_segment = side_adj.first_segment + side_adj.segment_count;
    for (side_adj.first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (hasEdgeInForwardRun(graph, segment.start, segment.count, target, globally_sorted)) return true;
    }
    return false;
}

pub fn hasEdgeInSideAdj(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, target: u32) bool {
    return hasEdgeInSideAdjChecked(graph, side_adj, target, false) catch false;
}

// ── Shape inspection, lookup helpers ────────────────────────────────────

pub fn searchInBlock(comptime BlockType: type, block: *const BlockType, alive: u7, target: u32) ?u7 {
    if (alive == 0) return null;

    const first = if (BlockType == types.EdgeBlockFwd) block.destinations[0] else block.sources[0];
    if (target < first or target > (if (BlockType == types.EdgeBlockFwd) block.destinations[alive - 1] else block.sources[alive - 1])) return null;

    var low: u7 = 0;
    var high: u7 = @intCast(alive);
    while (low < high) {
        const probe: u7 = low + (high - low) / 2;
        const probe_val = if (BlockType == types.EdgeBlockFwd) block.destinations[probe] else block.sources[probe];
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

fn forwardRunRangesMonotonic(graph: *const graph_core.GraphCore, start: u32, count: u32) bool {
    var prev_last: ?u32 = null;
    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        const alive = page_ops.blockAliveCount(graph, @intCast(block_idx), .fwd);
        if (alive == 0) continue;

        const first_edge = block.destinations[0];
        const last_edge = block.destinations[alive - 1];
        if (prev_last) |previous| {
            if (previous > first_edge) return false;
        }
        prev_last = last_edge;
    }
    return true;
}

fn hasEdgeInForwardRun(graph: *const graph_core.GraphCore, start: u32, count: u32, target: u32, globally_sorted: bool) bool {
    var low: u32 = 0;
    var high: u32 = count;
    var hit_empty = false;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block = page_ops.edgeBlockAtConst(graph, start + mid, .fwd);
        const alive = page_ops.blockAliveCount(graph, start + mid, .fwd);
        if (alive == 0) {
            hit_empty = true;
            break;
        }

        const first_edge = block.destinations[0];
        const last_edge = block.destinations[alive - 1];
        if (target < first_edge) {
            high = mid;
        } else if (target > last_edge) {
            low = mid + 1;
        } else {
            return searchInBlock(types.EdgeBlockFwd, block, alive, target) != null;
        }
    }

    // A published globally-sorted side makes a binary-search miss conclusive:
    // no monotonicity re-scan and no linear fallback are needed.
    if (globally_sorted and !hit_empty) return false;
    if (!hit_empty and forwardRunRangesMonotonic(graph, start, count)) return false;

    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        const block_alive_count = page_ops.blockAliveCount(graph, @intCast(block_idx), .fwd);
        if (searchInBlock(types.EdgeBlockFwd, block, block_alive_count, target) != null) return true;
    }
    return false;
}

pub fn hasEdgeInAdjChecked(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) !bool {
    return hasEdgeInSideAdjChecked(graph, sideAdjOfNode(node_adj, .fwd), target, false);
}

pub fn hasEdgeInAdj(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) bool {
    return hasEdgeInAdjChecked(graph, node_adj, target) catch false;
}

pub fn findTinyForwardSlotById(graph: *const graph_core.GraphCore, side_adj: types.SideAdj, destination_idx: u32, edge_id: u32) ?u7 {
    const slot = page_ops.tinySlotAtConst(graph, side_adj.first_block, .fwd);
    const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        if (entry.destination == destination_idx and entry.edge_id == edge_id) return @intCast(entry_idx);
    }
    return null;
}

// ── Multigraph helpers ─────────────────────────────────────────────────

/// Counts how many times `target` appears as a destination in forward blocks.
pub fn countForwardInBlock(block: *const types.EdgeBlockFwd, alive: u7, target: u32) u32 {
    if (alive == 0) return 0;
    if (target < block.destinations[0]) return 0;
    if (target > block.destinations[alive - 1]) return 0;

    var count: u32 = 0;
    for (0..alive) |slot| {
        if (block.destinations[slot] == target) {
            count += 1;
        } else if (block.destinations[slot] > target and count > 0) {
            break;
        }
    }
    return count;
}

/// Counts forward edges to `destination_idx` across an adjacency descriptor.
pub fn countForwardDestinationMatchesChecked(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    destination_idx: u32,
) !u32 {
    if (block_count == 0) return 0;

    const side_adj: types.SideAdj = .{
        .first_block = first_block,
        .block_count = block_count,
        .segment_count = segment_count,
        .first_segment = first_segment,
    };
    try validateSideAdjLayoutForSide(graph, side_adj, .fwd);

    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const slot = page_ops.tinySlotAtConst(graph, first_block, .fwd);
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
        var total_tiny: u32 = 0;
        for (0..count) |entry_idx| {
            if (slot.entries[entry_idx].destination == destination_idx) total_tiny += 1;
        }
        return total_tiny;
    }

    var total: u32 = 0;

    if (segment_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            total += countForwardInBlock(block, page_ops.blockAliveCount(graph, @intCast(block_idx), .fwd), destination_idx);
        }
        return total;
    }

    const end_segment = first_segment + segment_count;
    for (first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        for (segment.start..segment.start + segment.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            total += countForwardInBlock(block, page_ops.blockAliveCount(graph, @intCast(block_idx), .fwd), destination_idx);
        }
    }
    return total;
}

pub fn countForwardDestinationMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    destination_idx: u32,
) u32 {
    return countForwardDestinationMatchesChecked(
        graph,
        first_block,
        block_count,
        segment_count,
        first_segment,
        destination_idx,
    ) catch 0;
}

pub const ForwardBlockSlot = struct {
    block_idx: u32,
    slot: u7,
};

fn lowerBoundDestination(block: *const types.EdgeBlockFwd, alive: u7, target: u32) u7 {
    var low: u7 = 0;
    var high: u7 = alive;
    while (low < high) {
        const mid: u7 = low + (high - low) / 2;
        if (block.destinations[mid] < target) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn upperBoundDestination(block: *const types.EdgeBlockFwd, alive: u7, target: u32) u7 {
    var low: u7 = 0;
    var high: u7 = alive;
    while (low < high) {
        const mid: u7 = low + (high - low) / 2;
        if (block.destinations[mid] <= target) {
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
    alive: u7,
    destination_idx: u32,
    edge_id: u32,
) ?u7 {
    if (alive == 0) return null;
    if (destination_idx < block.destinations[0]) return null;
    if (destination_idx > block.destinations[alive - 1]) return null;

    const start = lowerBoundDestination(block, alive, destination_idx);
    if (start >= alive or block.destinations[start] != destination_idx) return null;
    const end = upperBoundDestination(block, alive, destination_idx);

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
    count: u32,
    destination_idx: u32,
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
        const alive = page_ops.blockAliveCount(graph, block_idx, .fwd);
        if (alive == 0) {
            hit_empty = true;
            break;
        }

        const first_edge = block.destinations[0];
        const last_edge = block.destinations[alive - 1];
        if (destination_idx < first_edge) {
            high = mid;
            continue;
        }
        if (destination_idx > last_edge) {
            low = mid + 1;
            continue;
        }

        const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
        if (searchForwardBlockSlotById(block, id_block, alive, destination_idx, edge_id)) |slot| {
            return .{ .block_idx = block_idx, .slot = slot };
        }

        var left = mid;
        while (left > 0) {
            const left_block_idx = start + left - 1;
            const left_block = page_ops.edgeBlockAtConst(graph, left_block_idx, .fwd);
            const left_alive = page_ops.blockAliveCount(graph, left_block_idx, .fwd);
            if (left_alive == 0) break;
            if (destination_idx < left_block.destinations[0] or destination_idx > left_block.destinations[left_alive - 1]) break;
            const left_ids = page_ops.edgeBlockFwdIdsAtConst(graph, left_block_idx);
            if (searchForwardBlockSlotById(left_block, left_ids, left_alive, destination_idx, edge_id)) |slot| {
                return .{ .block_idx = left_block_idx, .slot = slot };
            }
            left -= 1;
        }

        var right = mid + 1;
        while (right < count) : (right += 1) {
            const right_block_idx = start + right;
            const right_block = page_ops.edgeBlockAtConst(graph, right_block_idx, .fwd);
            const right_alive = page_ops.blockAliveCount(graph, right_block_idx, .fwd);
            if (right_alive == 0) break;
            if (destination_idx < right_block.destinations[0] or destination_idx > right_block.destinations[right_alive - 1]) break;
            const right_ids = page_ops.edgeBlockFwdIdsAtConst(graph, right_block_idx);
            if (searchForwardBlockSlotById(right_block, right_ids, right_alive, destination_idx, edge_id)) |slot| {
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
        const block_alive_count = page_ops.blockAliveCount(graph, block_idx, .fwd);
        if (searchForwardBlockSlotById(block, id_block, block_alive_count, destination_idx, edge_id)) |slot| {
            return .{ .block_idx = block_idx, .slot = slot };
        }
    }

    return null;
}

pub fn publishedNodeAdj(graph: *const graph_core.GraphCore, node: types.NodeId) !types.NodeAdj {
    try node_validity.ensureLiveNode(graph, node);
    return node_access.publishedAdjAtConst(graph, node);
}
