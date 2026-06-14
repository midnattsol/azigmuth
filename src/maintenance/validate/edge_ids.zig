const common = @import("common.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_published = @import("../../storage/node/published.zig");

const EdgeIdScan = struct {
    adjacency: types.NodeAdj,
    node_id: u32,
    max_seen: u32 = 0,
    allocator: ?std.mem.Allocator = null,
    violations: ?*std.ArrayList(types.Violation) = null,
    fail_fast: bool = false,
};

fn appendInvalidEdgeId(scan: *EdgeIdScan, block_idx: u32, slot: usize, edge_id: u32) !void {
    if (scan.fail_fast) return error.CorruptGraph;
    try scan.violations.?.append(scan.allocator.?, .{ .invalid_edge_id = .{
        .node = scan.node_id,
        .block = block_idx,
        .slot = @intCast(slot),
        .edge_id = edge_id,
    } });
}

fn appendDuplicateEdgeId(scan: *EdgeIdScan, edge_id: u32) !void {
    if (scan.fail_fast) return error.CorruptGraph;
    try scan.violations.?.append(scan.allocator.?, .{ .duplicate_edge_id = .{ .node = scan.node_id, .edge_id = edge_id } });
}

fn appendCounterRegression(scan: *EdgeIdScan, next_id: u32) !void {
    if (scan.fail_fast) return error.CorruptGraph;
    try scan.violations.?.append(scan.allocator.?, .{ .edge_id_counter_regressed = .{
        .node = scan.node_id,
        .next_id = next_id,
        .max_seen = scan.max_seen,
    } });
}

fn scanForwardEdgeIds(
    graph: *const graph_core.GraphCore,
    check_edge_id_counter: bool,
    node_id: u32,
    adjacency: types.NodeAdj,
    allocator: ?std.mem.Allocator,
    violations: ?*std.ArrayList(types.Violation),
    fail_fast: bool,
) !void {
    if (!graph.multigraph_enabled) return;
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;

    var scan = EdgeIdScan{
        .adjacency = adjacency,
        .node_id = node_id,
        .allocator = allocator,
        .violations = violations,
        .fail_fast = fail_fast,
    };

    try common.forEachForwardEntryInAdj(graph, adjacency, &scan, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_scan: *EdgeIdScan, entry: common.ForwardEntryView) !void {
            if (entry.edge_id == 0) try appendInvalidEdgeId(inner_scan, entry.block_idx, entry.slot, entry.edge_id);
            inner_scan.max_seen = @max(inner_scan.max_seen, entry.edge_id);
            if (edgeIdAppearsLater(inner_graph, inner_scan.adjacency, entry.block_idx, entry.slot, entry.edge_id)) {
                try appendDuplicateEdgeId(inner_scan, entry.edge_id);
            }
        }
    }.callback);

    if (check_edge_id_counter) {
        const next_id = page_ops.nodeHotAtConst(graph, .{ .index = node_id }).loadNextLocalEdgeId();
        if (scan.max_seen >= next_id) try appendCounterRegression(&scan, next_id);
    }
}

fn edgeIdAppearsLater(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    current_block_idx: u32,
    current_slot: usize,
    edge_id: u32,
) bool {
    if (common.groupCount(adjacency, .fwd) == 0) {
        const side_adj = common.sideAdjOf(adjacency, .fwd);
        if (node_published.NodePublished.isTiny(&side_adj)) {
            const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
            const count = node_published.NodePublished.tinyCount(&side_adj);
            for (current_slot + 1..count) |slot_idx| {
                if (slot.entries[slot_idx].edge_id == edge_id) return true;
            }
            return false;
        }
        for (common.firstBlock(adjacency, .fwd)..common.firstBlock(adjacency, .fwd) + common.blockCount(adjacency, .fwd)) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
            const live_count = @min(page_ops.blockLiveCount(graph, block_idx, .fwd), constants.EDGES_PER_BLOCK);
            const slot_start: usize = if (block_idx == current_block_idx) current_slot + 1 else 0;
            for (slot_start..live_count) |slot| {
                if (id_block.ids[slot] == edge_id) return true;
            }
        }
        return false;
    }

    const first_group_idx = common.firstGroup(adjacency, .fwd);
    const end_group = first_group_idx + common.groupCount(adjacency, .fwd);
    if (end_group > graph.loadGroupCount()) return false;
    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
            const live_count = @min(page_ops.blockLiveCount(graph, block_idx, .fwd), constants.EDGES_PER_BLOCK);
            const slot_start: usize = if (block_idx == current_block_idx) current_slot + 1 else 0;
            for (slot_start..live_count) |slot| {
                if (id_block.ids[slot] == edge_id) return true;
            }
        }
    }
    return false;
}

pub fn appendForwardEdgeIdViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardEdgeIds(graph, true, node_id, adjacency, allocator, violations, false);
}

pub fn appendForwardEdgeIdViolationsSnapshot(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardEdgeIds(graph, false, node_id, adjacency, allocator, violations, false);
}

pub fn validateForwardEdgeIdsFast(
    graph: *const graph_core.GraphCore,
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardEdgeIds(graph, true, node_id, adjacency, null, null, true);
}
