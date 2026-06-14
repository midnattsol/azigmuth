const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_published = @import("../../storage/node/published.zig");
const rcu = @import("../../concurrency/rcu.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");
const node_validity = @import("../../core/node_validity.zig");

const LiveTotal = struct { value: u64 = 0 };
pub fn validateBlockDense(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) !void {
    if (!common.blockExists(graph, block_idx, side)) return error.CorruptGraph;

    // Dense storage is structural now (entries occupy [0, live)); the only
    // representable corruption is a live count beyond block capacity.
    if (common.blockLive(graph, block_idx, side) > constants.EDGES_PER_BLOCK) return error.CorruptGraph;
}

pub fn validateDenseInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    comptime side: common.Side,
) !void {
    for (start..start + count) |block_idx| {
        try validateBlockDense(graph, @intCast(block_idx), side);
    }
}

pub fn validateDenseInGroupedRuns(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    group_count: u16,
    comptime side: common.Side,
) !void {
    const end_group = std.math.add(u32, first_group, group_count) catch return error.CorruptGraph;
    if (end_group > graph.loadGroupCount()) return error.CorruptGraph;
    for (first_group..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        try validateDenseInContiguousBlocks(graph, group.start, group.count, side);
    }
}

pub fn validateDenseMasks(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !void {
    return common.forEachRunInAdj(graph, adjacency, side, {}, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            _: void,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            try validateDenseInContiguousBlocks(inner_graph, start, count, side);
        }
    }.callback);
}

pub fn validateBlockShapeFast(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: common.Side) !u64 {
    if (!common.blockExists(graph, block_idx, side)) return error.CorruptGraph;
    const node_count = graph.publishedNodeCount();

    if (side == .fwd) {
        const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
        const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx) else null;
        const live_count = page_ops.blockLiveCount(graph, block_idx, .fwd);
        if (live_count > constants.EDGES_PER_BLOCK) return error.CorruptGraph;
        var prev: u32 = 0;
        var prev_id: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.destinations[slot];
            if (key >= node_count) return error.CorruptGraph;
            if (graph.multigraph_enabled) {
                const edge_id = id_block.?.ids[slot];
                if (edge_id == 0) return error.CorruptGraph;
                if (slot > 0) {
                    if (key < prev) return error.CorruptGraph;
                    if (key == prev and edge_id <= prev_id) return error.CorruptGraph;
                }
                prev_id = edge_id;
            } else if (slot > 0 and key <= prev) {
                return error.CorruptGraph;
            }
            prev = key;
        }
        return live_count;
    } else {
        const block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
        const live_count = page_ops.blockLiveCount(graph, block_idx, .rev);
        if (live_count > constants.EDGES_PER_BLOCK) return error.CorruptGraph;
        var prev: u32 = 0;
        for (0..live_count) |slot| {
            const key = block.sources[slot];
            if (key >= node_count) return error.CorruptGraph;
            if (slot > 0 and (key < prev or (!graph.multigraph_enabled and key == prev))) return error.CorruptGraph;
            prev = key;
        }
        return live_count;
    }
}

pub fn validateContiguousBlocksFast(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    comptime side: common.Side,
) !u64 {
    var total: u64 = 0;
    for (start..start + count) |block_idx| {
        total += try validateBlockShapeFast(graph, @intCast(block_idx), side);
    }
    return total;
}

pub fn validateGroupedRunsFast(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    expected_group_count: u16,
    comptime side: common.Side,
) !u64 {
    var total: u64 = 0;
    const end_group = std.math.add(u32, first_group, expected_group_count) catch return error.CorruptGraph;
    if (end_group > graph.loadGroupCount()) return error.CorruptGraph;
    for (first_group..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        if (group.count == 0) return error.CorruptGraph;
        total += try validateContiguousBlocksFast(graph, group.start, group.count, side);
    }
    return total;
}

/// Tiny forward entries: destinations in range and strictly ascending
/// (multigraph: ascending with edge ids strictly ascending within ties,
/// and ids never zero).
fn validateTinyFwdEntriesFast(graph: *const graph_core.GraphCore, slot_idx: u32, count: u16) !void {
    const slot = page_ops.tinyBlockAtConst(graph, slot_idx, .fwd);
    var prev_key: ?u32 = null;
    var prev_id: u32 = 0;
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        if (entry.destination >= graph.publishedNodeCount()) return error.CorruptGraph;
        if (!graph.multigraph_enabled) {
            if (prev_key) |previous| {
                if (entry.destination <= previous) return error.CorruptGraph;
            }
            prev_key = entry.destination;
            continue;
        }
        if (entry.edge_id == 0) return error.CorruptGraph;
        if (prev_key) |previous| {
            if (entry.destination < previous) return error.CorruptGraph;
            if (entry.destination == previous and entry.edge_id <= prev_id) return error.CorruptGraph;
        }
        prev_id = entry.edge_id;
        prev_key = entry.destination;
    }
}

/// Tiny reverse sources: in range and ascending (strict outside multigraph).
fn validateTinyRevSourcesFast(graph: *const graph_core.GraphCore, slot_idx: u32, count: u16) !void {
    const slot = page_ops.tinyBlockAtConst(graph, slot_idx, .rev);
    var prev_key: ?u32 = null;
    for (0..count) |entry_idx| {
        const source_idx = slot.sources[entry_idx];
        if (source_idx >= graph.publishedNodeCount()) return error.CorruptGraph;
        if (prev_key) |previous| {
            if (source_idx < previous or (!graph.multigraph_enabled and source_idx == previous)) return error.CorruptGraph;
        }
        prev_key = source_idx;
    }
}

pub fn validateAdjacencyBlocksFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !u64 {
    const side_adj = common.sideAdjOf(adjacency, side);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const count = node_published.NodePublished.tinyCount(&side_adj);
        switch (side) {
            .fwd => try validateTinyFwdEntriesFast(graph, side_adj.first_block, count),
            .rev => try validateTinyRevSourcesFast(graph, side_adj.first_block, count),
        }
        return count;
    }

    var total = LiveTotal{};
    try common.forEachRunInAdj(graph, adjacency, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *LiveTotal,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            inner_total.value += try validateContiguousBlocksFast(inner_graph, start, count, side);
        }
    }.callback);
    return total.value;
}

pub fn validateOccupancyFast(graph: *const graph_core.GraphCore, adjacency: types.NodeAdj, comptime side: common.Side) !void {
    if (node_published.NodePublished.isTiny(&common.sideAdjOf(adjacency, side))) return;
    const block_count = common.blockCount(adjacency, side);
    if (block_count <= 1) return;

    try common.forEachRunInAdj(graph, adjacency, side, graph, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            _: *const graph_core.GraphCore,
            start: u32,
            run_count: u32,
            is_last: bool,
        ) !void {
            const end = if (is_last) start + run_count - 1 else start + run_count;
            for (start..end) |block_idx| {
                if (common.blockLive(inner_graph, @intCast(block_idx), side) < constants.MIN_OCCUPANCY) {
                    return error.CorruptGraph;
                }
            }
        }
    }.callback);
}
