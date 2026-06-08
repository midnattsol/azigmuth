const common = @import("common.zig");
const run_search = @import("run_search.zig");
const edge_ids = @import("edge_ids.zig");
const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
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

fn appendForwardMismatch(allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, destination_node: u32) !void {
    try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = source_node, .dst = destination_node } });
}

fn checkForwardPair(graph: *const graph_core.GraphCore, source_node: u32, source_adjacency: types.NodeAdj, destination_node: u32) !void {
    if (destination_node >= graph.publishedNodeCount()) return error.CorruptGraph;
    const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
    if (destination_adjacency.flags.removed) return;
    if (graph.multigraph_enabled) {
        const forward_count = run_search.countTargetMatches(graph, source_adjacency, destination_node, .fwd);
        const reverse_count = run_search.countTargetMatches(graph, destination_adjacency, source_node, .rev);
        if (forward_count != reverse_count) return error.CorruptGraph;
        return;
    }
    if (!run_search.adjacencyContains(graph, destination_adjacency, source_node, .rev)) return error.CorruptGraph;
}

fn appendForwardPairViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, source_adjacency: types.NodeAdj, destination_node: u32) !void {
    if (destination_node >= graph.publishedNodeCount()) return;
    const destination_adjacency = page_ops.nodeAtConst(graph, .{ .index = destination_node }).publishedAdj();
    if (destination_adjacency.flags.removed) return;
    if (graph.multigraph_enabled) {
        const forward_count = run_search.countTargetMatches(graph, source_adjacency, destination_node, .fwd);
        const reverse_count = run_search.countTargetMatches(graph, destination_adjacency, source_node, .rev);
        if (forward_count != reverse_count) {
            try violations.append(allocator, .{ .forward_reverse_multiplicity_mismatch = .{ .node = source_node, .dst = destination_node, .forward_count = forward_count, .reverse_count = reverse_count } });
        }
        return;
    }
    if (!run_search.adjacencyContains(graph, destination_adjacency, source_node, .rev)) {
        try appendForwardMismatch(allocator, violations, source_node, destination_node);
    }
}

fn checkReversePair(graph: *const graph_core.GraphCore, source_node: u32, destination_node: u32) !void {
    if (source_node >= graph.publishedNodeCount()) return error.CorruptGraph;
    const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
    if (source_adjacency.flags.removed) return;
    if (!run_search.adjacencyContains(graph, source_adjacency, destination_node, .fwd)) return error.CorruptGraph;
}

fn appendReversePairViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, destination_node: u32) !void {
    if (source_node >= graph.publishedNodeCount()) return;
    const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
    if (source_adjacency.flags.removed) return;
    if (!run_search.adjacencyContains(graph, source_adjacency, destination_node, .fwd)) {
        try appendForwardMismatch(allocator, violations, source_node, destination_node);
    }
}

fn validateForwardRun(graph: *const graph_core.GraphCore, source_node: u32, start: u32, count: u16) !void {
    try validateForwardConsistencyInContiguousBlocks(graph, source_node, start, count);
}

fn validateReverseRun(graph: *const graph_core.GraphCore, destination_node: *u32, start: u32, count: u16) !void {
    try validateReverseConsistencyInContiguousBlocks(graph, destination_node.*, start, count);
}

fn validateForwardMultiplicityRun(graph: *const graph_core.GraphCore, context: *const ForwardMultiplicityContext, start: u32, count: u16) !void {
    try validateForwardMultiplicityInContiguousBlocks(graph, context.source_node, context.adjacency, start, count);
}

pub fn appendForwardConsistencyViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, blocks: []const common.TraversedBlock) !void {
    if (!node_validity.isNodeLiveIndex(graph, source_node)) return;
    const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .fwd)) continue;
        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            try appendForwardPairViolations(graph, allocator, violations, source_node, source_adjacency, block.edges[slot].destination);
        }
    }
}

pub fn appendReverseConsistencyViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), destination_node: u32, blocks: []const common.TraversedBlock) !void {
    if (!node_validity.isNodeLiveIndex(graph, destination_node)) return;
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_index, .rev)) continue;
        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_index, .rev);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            try appendReversePairViolations(graph, allocator, violations, block.sources[slot], destination_node);
        }
    }
}

fn validateForwardMultiplicityInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, source_adjacency: types.NodeAdj, start: u32, count: u16) !void {
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            try checkForwardPair(graph, source_node, source_adjacency, block.edges[slot].destination);
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
    const source_adjacency = page_ops.nodeAtConst(graph, .{ .index = source_node }).publishedAdj();
    for (start..start + count) |block_index| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
        const live_count = @popCount(block.mask);
        for (0..live_count) |slot| {
            try checkForwardPair(graph, source_node, source_adjacency, block.edges[slot].destination);
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
            try checkReversePair(graph, block.sources[slot], destination_node);
        }
    }
}
