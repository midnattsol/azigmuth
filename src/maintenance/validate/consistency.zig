const common = @import("common.zig");
const run_search = @import("run_search.zig");
const edge_ids = @import("edge_ids.zig");
const layout_debt = @import("../layout_debt.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");

pub const runContainsTarget = run_search.runContainsTarget;
pub const findSlotInRun = run_search.findSlotInRun;
pub const adjacencyContains = run_search.adjacencyContains;
pub const appendForwardEdgeIdViolations = edge_ids.appendForwardEdgeIdViolations;
pub const validateForwardEdgeIdsFast = edge_ids.validateForwardEdgeIdsFast;

const ForwardMultiplicityContext = struct {
    source_node: u32,
    adjacency: types.NodeAdj,
};

fn validateForwardRun(
    graph: *const graph_core.GraphCore,
    source_node: u32,
    start: u32,
    count: u16,
) !void {
    try validateForwardConsistencyInContiguousBlocks(graph, source_node, start, count);
}

fn validateReverseRun(
    graph: *const graph_core.GraphCore,
    destination_node: *u32,
    start: u32,
    count: u16,
) !void {
    try validateReverseConsistencyInContiguousBlocks(graph, destination_node.*, start, count);
}

fn validateForwardMultiplicityRun(
    graph: *const graph_core.GraphCore,
    context: *const ForwardMultiplicityContext,
    start: u32,
    count: u16,
) !void {
    try validateForwardMultiplicityInContiguousBlocks(graph, context.source_node, context.adjacency, start, count);
}

pub fn appendForwardConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    source_node: u32,
    blocks: []const common.TraversedBlock,
) !void {
    if (!node_validity.isNodeLiveIndex(graph, source_node)) return;

    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .fwd)) continue;

        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .fwd);
        const live_count = @popCount(block.mask);
        const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();

        for (0..live_count) |slot| {
            const destination_node = block.edges[slot].destination;
            if (destination_node >= graph.publishedNodeCount()) continue;

            const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
            if (destination_adjacency.flags.removed) continue;
            if (graph.multigraph_enabled) {
                const forward_count = run_search.countTargetMatches(graph, source_adjacency, destination_node, .fwd);
                const reverse_count = run_search.countTargetMatches(graph, destination_adjacency, source_node, .rev);
                if (forward_count != reverse_count) {
                    try violations.append(allocator, .{ .forward_reverse_multiplicity_mismatch = .{
                        .node = source_node,
                        .dst = destination_node,
                        .forward_count = forward_count,
                        .reverse_count = reverse_count,
                    } });
                }
            } else if (!run_search.adjacencyContains(graph, destination_adjacency, source_node, .rev)) {
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
    if (!node_validity.isNodeLiveIndex(graph, destination_node)) return;

    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .rev)) continue;

        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .rev);
        const live_count = @popCount(block.mask);

        for (0..live_count) |slot| {
            const source_node = block.sources[slot];
            if (source_node >= graph.publishedNodeCount()) continue;

            const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
            if (source_adjacency.flags.removed) continue;
            if (!run_search.adjacencyContains(graph, source_adjacency, destination_node, .fwd)) {
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
    const side_view: types.SideAdj = switch (side) {
        .fwd => .{
            .first_block = adjacency.first_block_fwd,
            .block_count = adjacency.block_count_fwd,
            .group_count = adjacency.group_count_fwd,
            .first_group = adjacency.first_group_fwd,
        },
        .rev => .{
            .first_block = adjacency.first_block_rev,
            .block_count = adjacency.block_count_rev,
            .group_count = adjacency.group_count_rev,
            .first_group = adjacency.first_group_rev,
        },
    };
    if (side_view.group_count == 0) return;

    const side_tag = switch (side) {
        .fwd => adjacency_mod.AdjSide.fwd,
        .rev => adjacency_mod.AdjSide.rev,
    };
    const report = layout_debt.analyzeSideLayout(graph, side_view, side_tag) catch {
        try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = common.firstGroup(adjacency, side) } });
        return;
    };

    if (!common.needsRepairFlag(adjacency, side)) {
        const ViolationContext = struct {
            allocator: std.mem.Allocator,
            violations: *std.ArrayList(types.Violation),
            node_id: u32,
        };
        var context = ViolationContext{
            .allocator = allocator,
            .violations = violations,
            .node_id = node_id,
        };
        try layout_debt.forEachGroupInSide(graph, side_view, side_tag, &context, struct {
            fn callback(
                _: *const graph_core.GraphCore,
                violation_context: *ViolationContext,
                group_idx: u32,
                group: types.EdgeBlockGroup,
                is_last_group: bool,
            ) !void {
                if (!is_last_group and group.count < 4) {
                    try violation_context.violations.append(violation_context.allocator, .{ .run_fragmentation_requires_repair = .{
                        .node = violation_context.node_id,
                        .group = group_idx,
                        .count = group.count,
                    } });
                }
            }
        }.callback);
    }

    if (report.chain_is_contiguous and !common.needsRepairFlag(adjacency, side)) {
        try violations.append(allocator, .{ .grouped_layout_needs_canonicalization = .{
            .node = node_id,
            .first_group = common.firstGroup(adjacency, side),
        } });
    }
}

fn validateForwardMultiplicityInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    source_node: u32,
    source_adjacency: types.NodeAdj,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            const destination_node = block.edges[slot].destination;
            if (destination_node >= graph.publishedNodeCount()) return error.CorruptGraph;

            const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
            if (destination_adjacency.flags.removed) continue;

            const forward_count = run_search.countTargetMatches(graph, source_adjacency, destination_node, .fwd);
            const reverse_count = run_search.countTargetMatches(graph, destination_adjacency, source_node, .rev);
            if (forward_count != reverse_count) return error.CorruptGraph;
        }
    }
}

pub fn validateForwardConsistencyFast(graph: *const graph_core.GraphCore, source_node: u32, adjacency: types.NodeAdj) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;

    if (graph.multigraph_enabled) {
        const context = ForwardMultiplicityContext{ .source_node = source_node, .adjacency = adjacency };
        try run_search.forEachRunInAdj(graph, adjacency, .fwd, &context, validateForwardMultiplicityRun);
        return;
    }

    try run_search.forEachRunInAdj(graph, adjacency, .fwd, source_node, validateForwardRun);
}

pub fn validateForwardConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, start: u32, count: u16) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            const destination_node = block.edges[slot].destination;
            if (destination_node >= graph.publishedNodeCount()) return error.CorruptGraph;

            const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
            if (destination_adjacency.flags.removed) continue;
            if (!run_search.adjacencyContains(graph, destination_adjacency, source_node, .rev)) return error.CorruptGraph;
        }
    }
}

pub fn validateReverseConsistencyFast(graph: *const graph_core.GraphCore, destination_node: u32, adjacency: types.NodeAdj) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .rev) == 0) return;

    var destination_ctx = destination_node;
    try run_search.forEachRunInAdj(graph, adjacency, .rev, &destination_ctx, validateReverseRun);
}

pub fn validateReverseConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, destination_node: u32, start: u32, count: u16) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .rev);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            const source_node = block.sources[slot];
            if (source_node >= graph.publishedNodeCount()) return error.CorruptGraph;

            const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
            if (source_adjacency.flags.removed) continue;
            if (!run_search.adjacencyContains(graph, source_adjacency, destination_node, .fwd)) return error.CorruptGraph;
        }
    }
}
