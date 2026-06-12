const common = @import("common.zig");
const run_search = @import("run_search.zig");
const edge_ids = @import("edge_ids.zig");
const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_validity = @import("../../core/node_validity.zig");

pub const runContainsTarget = run_search.runContainsTarget;
pub const findSlotInRun = run_search.findSlotInRun;
pub const adjacencyContains = run_search.adjacencyContains;
pub const appendForwardEdgeIdViolations = edge_ids.appendForwardEdgeIdViolations;
pub const appendForwardEdgeIdViolationsSnapshot = edge_ids.appendForwardEdgeIdViolationsSnapshot;
pub const validateForwardEdgeIdsFast = edge_ids.validateForwardEdgeIdsFast;

const ForwardMultiplicityContext = struct {
    source_node: u32,
    adjacency: types.NodeAdj,
};

fn appendForwardMismatch(allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, destination_node: u32) !void {
    try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = source_node, .destination = destination_node } });
}

fn checkForwardPair(graph: *const graph_core.GraphCore, source_node: u32, source_adjacency: types.NodeAdj, destination_node: u32) !void {
    if (destination_node >= graph.publishedNodeCount()) return error.CorruptGraph;
    const destination_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = destination_node });
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
    const destination_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = destination_node });
    if (destination_adjacency.flags.removed) return;
    if (graph.multigraph_enabled) {
        const forward_count = run_search.countTargetMatches(graph, source_adjacency, destination_node, .fwd);
        const reverse_count = run_search.countTargetMatches(graph, destination_adjacency, source_node, .rev);
        if (forward_count != reverse_count) {
            try violations.append(allocator, .{ .forward_reverse_multiplicity_mismatch = .{ .node = source_node, .destination = destination_node, .forward_count = forward_count, .reverse_count = reverse_count } });
        }
        return;
    }
    if (!run_search.adjacencyContains(graph, destination_adjacency, source_node, .rev)) {
        try appendForwardMismatch(allocator, violations, source_node, destination_node);
    }
}

fn checkReversePair(graph: *const graph_core.GraphCore, source_node: u32, destination_node: u32) !void {
    if (source_node >= graph.publishedNodeCount()) return error.CorruptGraph;
    const source_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = source_node });
    if (source_adjacency.flags.removed) return;
    if (!run_search.adjacencyContains(graph, source_adjacency, destination_node, .fwd)) return error.CorruptGraph;
}

fn appendReversePairViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), source_node: u32, destination_node: u32) !void {
    if (source_node >= graph.publishedNodeCount()) return;
    const source_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = source_node });
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
    const source_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = source_node });
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_idx, .fwd)) continue;
        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_idx, .fwd);
        const live_count = @min(page_ops.blockLiveCount(graph, traversed_block.block_idx, .fwd), constants.EDGES_PER_BLOCK);
        for (0..live_count) |slot| {
            try appendForwardPairViolations(graph, allocator, violations, source_node, source_adjacency, block.destinations[slot]);
        }
    }
}

pub fn appendReverseConsistencyViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), destination_node: u32, blocks: []const common.TraversedBlock) !void {
    if (!node_validity.isNodeLiveIndex(graph, destination_node)) return;
    for (blocks) |traversed_block| {
        if (!common.blockExists(graph, traversed_block.block_idx, .rev)) continue;
        const block = page_ops.edgeBlockAtConst(graph, traversed_block.block_idx, .rev);
        const live_count = @min(page_ops.blockLiveCount(graph, traversed_block.block_idx, .rev), constants.EDGES_PER_BLOCK);
        for (0..live_count) |slot| {
            try appendReversePairViolations(graph, allocator, violations, block.sources[slot], destination_node);
        }
    }
}

fn validateForwardMultiplicityInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, source_adjacency: types.NodeAdj, start: u32, count: u16) !void {
    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        const live_count = @min(page_ops.blockLiveCount(graph, @intCast(block_idx), .fwd), 64);
        for (0..live_count) |slot| {
            try checkForwardPair(graph, source_node, source_adjacency, block.destinations[slot]);
        }
    }
}

pub fn validateForwardConsistencyFast(graph: *const graph_core.GraphCore, source_node: u32, adjacency: types.NodeAdj) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;
    if (graph.multigraph_enabled) {
        try common.forEachForwardEntryInAdj(graph, adjacency, ForwardMultiplicityContext{ .source_node = source_node, .adjacency = adjacency }, struct {
            fn callback(inner_graph: *const graph_core.GraphCore, context: ForwardMultiplicityContext, entry: common.ForwardEntryView) !void {
                try checkForwardPair(inner_graph, context.source_node, context.adjacency, entry.destination);
            }
        }.callback);
        return;
    }
    // The source adjacency is loop-invariant: compose it once, not per entry.
    try common.forEachForwardEntryInAdj(graph, adjacency, ForwardMultiplicityContext{ .source_node = source_node, .adjacency = adjacency }, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, context: ForwardMultiplicityContext, entry: common.ForwardEntryView) !void {
            try checkForwardPair(inner_graph, context.source_node, context.adjacency, entry.destination);
        }
    }.callback);
}

pub fn validateForwardConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, source_node: u32, start: u32, count: u16) !void {
    const source_adjacency = node_access.publishedAdjAtConst(graph, .{ .index = source_node });
    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
        const live_count = @min(page_ops.blockLiveCount(graph, @intCast(block_idx), .fwd), 64);
        for (0..live_count) |slot| {
            try checkForwardPair(graph, source_node, source_adjacency, block.destinations[slot]);
        }
    }
}

pub fn validateReverseConsistencyFast(graph: *const graph_core.GraphCore, destination_node: u32, adjacency: types.NodeAdj) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .rev) == 0) return;
    try common.forEachNodeIdInAdj(graph, adjacency, .rev, destination_node, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_destination_node: u32, source_node: u32) !void {
            try checkReversePair(inner_graph, source_node, inner_destination_node);
        }
    }.callback);
}

pub fn validateReverseConsistencyInContiguousBlocks(graph: *const graph_core.GraphCore, destination_node: u32, start: u32, count: u16) !void {
    for (start..start + count) |block_idx| {
        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
        const live_count = @min(page_ops.blockLiveCount(graph, @intCast(block_idx), .rev), 64);
        for (0..live_count) |slot| {
            try checkReversePair(graph, block.sources[slot], destination_node);
        }
    }
}
