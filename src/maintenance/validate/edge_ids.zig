const common = @import("common.zig");
const run_search = @import("run_search.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");

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

fn scanForwardEdgeIdRun(
    graph: *const graph_core.GraphCore,
    scan: *EdgeIdScan,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
        const live_count = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, .fwd).mask);
        for (0..live_count) |slot| {
            const edge_id = id_block.ids[slot];
            if (edge_id == 0) try appendInvalidEdgeId(scan, block_idx, slot, edge_id);
            scan.max_seen = @max(scan.max_seen, edge_id);
            if (edgeIdAppearsLater(graph, scan.adjacency, block_idx, slot, edge_id)) {
                try appendDuplicateEdgeId(scan, edge_id);
            }
        }
    }
}

fn scanForwardEdgeIds(
    graph: *const graph_core.GraphCore,
    node_buffer: *const types.NodeBuffer,
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
    try run_search.forEachRunInAdj(graph, adjacency, .fwd, &scan, scanForwardEdgeIdRun);

    const next_id = node_buffer.next_local_edge_id.load(.acquire);
    if (scan.max_seen >= next_id) try appendCounterRegression(&scan, next_id);
}

fn edgeIdAppearsLater(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    current_block_idx: u32,
    current_slot: usize,
    edge_id: u32,
) bool {
    if (common.groupCount(adjacency, .fwd) == 0) {
        for (common.firstBlock(adjacency, .fwd)..common.firstBlock(adjacency, .fwd) + common.blockCount(adjacency, .fwd)) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
            const live_count = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, .fwd).mask);
            const slot_start: usize = if (block_idx == current_block_idx) current_slot + 1 else 0;
            for (slot_start..live_count) |slot| {
                if (id_block.ids[slot] == edge_id) return true;
            }
        }
        return false;
    }

    const first_group_idx = common.firstGroup(adjacency, .fwd);
    const end_group = first_group_idx + common.groupCount(adjacency, .fwd);
    if (end_group > graph.group_count) return false;
    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const id_block = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
            const live_count = @popCount(page_ops.edgeBlockAtConst(graph, block_idx, .fwd).mask);
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
    node_buffer: *const types.NodeBuffer,
    adjacency: types.NodeAdj,
) !void {
    try scanForwardEdgeIds(graph, node_buffer, node_id, adjacency, allocator, violations, false);
}

pub fn validateForwardEdgeIdsFast(
    graph: *const graph_core.GraphCore,
    node_buffer: *const types.NodeBuffer,
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    _ = node_id;
    try scanForwardEdgeIds(graph, node_buffer, 0, adjacency, null, null, true);
}
