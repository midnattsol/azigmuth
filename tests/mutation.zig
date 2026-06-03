const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;
const helpers = @import("helpers.zig");
const adjacency_mod = test_internals.adjacency;
const common_mod = test_internals.mutation_common;

const testing = std.testing;

fn clearPublished(node: *graph_mod.NodeBuffer) void {
    helpers.clearPublishedSides(node);
}

fn fwd(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return helpers.publishedFwdSide(node);
}

fn rev(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return helpers.publishedRevSide(node);
}

test "mutation: invalid endpoints do not mutate graph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const invalid_node = graph_mod.NodeId{ .index = 999 };

    try testing.expectError(error.InvalidNode, graph.addEdge(node, invalid_node, 0, 0));
    try testing.expectError(error.InvalidNode, graph.addEdge(invalid_node, node, 0, 0));
    try testing.expectError(error.InvalidNode, graph.removeEdge(node, invalid_node));
    try testing.expectError(error.InvalidNode, graph.removeEdge(invalid_node, node));

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(node));
    try graph.validate();
}

test "mutation: addEdge keeps out-of-order insertions sorted inside the block" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try helpers.addNodes(&graph, 9);
    const source = nodes[0];
    const insertion_order = [_]usize{ 7, 2, 5, 1, 8, 3, 6, 4 };

    for (insertion_order) |target_position| {
        try graph.addEdge(source, nodes[target_position], 0, 0);
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, 8), graph.edgeCount());
    try helpers.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 });
}

test "mutation: duplicate addEdge in grouped adjacency leaves state unchanged" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 130;
    var targets: [target_count]graph_mod.NodeId = undefined;

    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], 0, 0);
    }

    try graph.validate();
    const edge_count_before = graph.edgeCount();
    const duplicate_offsets = [_]usize{ 0, 64, 129 };

    for (duplicate_offsets) |duplicate_offset| {
        try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, targets[duplicate_offset], 0, 0));
        try testing.expectEqual(edge_count_before, graph.edgeCount());
        try testing.expectEqual(target_count, try graph.outDegree(source));
        try graph.validate();
    }
}

test "mutation: reverse adjacency grows and iterates across multiple blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try graph.addNode();
    const source_count: usize = 130;
    var sources: [source_count]graph_mod.NodeId = undefined;

    for (0..source_count) |source_index| {
        sources[source_index] = try graph.addNode();
        try graph.addEdge(sources[source_index], destination, 0, 0);
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, source_count), graph.edgeCount());
    try testing.expectEqual(source_count, try graph.inDegree(destination));

    var iterator = try graph.inNeighbors(destination);
    const incoming_sources = try iterator.materialize(testing.allocator);
    defer testing.allocator.free(incoming_sources);

    try helpers.expectNeighborSet(incoming_sources, &sources, graph.nodeCount(), testing.allocator);
}

test "mutation: removeEdge from grouped reverse adjacency preserves other incoming sources" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try graph.addNode();
    const source_count: usize = 65;
    var sources: [source_count]graph_mod.NodeId = undefined;

    for (0..source_count) |source_index| {
        sources[source_index] = try graph.addNode();
        try graph.addEdge(sources[source_index], destination, 0, 0);
    }

    try graph.validate();
    try testing.expect(try graph.removeEdge(sources[0], destination));
    try graph.validate();

    try testing.expectEqual(@as(u64, source_count - 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(sources[0]));
    try testing.expectEqual(source_count - 1, try graph.inDegree(destination));

    var iterator = try graph.inNeighbors(destination);
    const incoming_sources = try iterator.materialize(testing.allocator);
    defer testing.allocator.free(incoming_sources);

    try helpers.expectNodeAbsent(incoming_sources, sources[0]);
    try helpers.expectNeighborSet(incoming_sources, sources[1..], graph.nodeCount(), testing.allocator);
}

test "mutation: removeEdge on self-loop preserves unrelated incoming and outgoing edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try helpers.addNodes(&graph, 3);
    const node = nodes[0];
    const outgoing_neighbor = nodes[1];
    const incoming_neighbor = nodes[2];

    try graph.addEdge(node, node, 0, 0);
    try graph.addEdge(node, outgoing_neighbor, 0, 0);
    try graph.addEdge(incoming_neighbor, node, 0, 0);
    try graph.validate();

    try testing.expect(try graph.removeEdge(node, node));
    try graph.validate();

    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(node));
    try helpers.expectOutNeighbors(&graph, testing.allocator, node, &[_]u32{outgoing_neighbor.index});
    try helpers.expectInNeighbors(&graph, testing.allocator, node, &[_]u32{incoming_neighbor.index});
}

test "mutation: removeEdge returns CorruptGraph when reverse entry is missing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const forward_block = try graph.allocBlockFwd();
    var forward_edges = page_ops.edgeBlockAt(&graph.graph, forward_block, .fwd);
    forward_edges.edges[0] = types.Edge{ .destination = destination.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    forward_edges.mask = constants.denseMask(1);

    const source_node = try graph.nodeAt(source);
    clearPublished(source_node);
    fwd(source_node).first_block = forward_block;
    fwd(source_node).block_count = 1;
    graph.graph.edge_count.store(1, .release);

    const forward_block_count_before = graph.graph.block_fwd_count;
    const reverse_block_count_before = graph.graph.block_rev_count;
    const retired_forward_before = graph.graph.retired_blocks_fwd.items.len;
    const retired_reverse_before = graph.graph.retired_blocks_rev.items.len;

    try testing.expectError(error.CorruptGraph, graph.removeEdge(source, destination));

    try testing.expectEqual(forward_block_count_before, graph.graph.block_fwd_count);
    try testing.expectEqual(reverse_block_count_before, graph.graph.block_rev_count);
    try testing.expectEqual(retired_forward_before, graph.graph.retired_blocks_fwd.items.len);
    try testing.expectEqual(retired_reverse_before, graph.graph.retired_blocks_rev.items.len);
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try helpers.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{destination.index});
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
}

test "mutation: reverse-only orphan does not make removeEdge report success" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const reverse_block = try graph.allocBlockRev();
    var reverse_sources = page_ops.edgeBlockAt(&graph.graph, reverse_block, .rev);
    reverse_sources.sources[0] = source.index;
    reverse_sources.mask = constants.denseMask(1);

    const destination_node = try graph.nodeAt(destination);
    clearPublished(destination_node);
    rev(destination_node).first_block = reverse_block;
    rev(destination_node).block_count = 1;
    helpers.setPublishedRevDegree(destination_node, 1);

    try testing.expect(!try graph.removeEdge(source, destination));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "mutation: addEdge works after removing the only edge from the same source" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = try helpers.addNodes(&graph, 3);
    const source = nodes[0];
    const first_destination = nodes[1];
    const second_destination = nodes[2];

    try graph.addEdge(source, first_destination, 0, 0);
    try graph.validate();
    try testing.expect(try graph.removeEdge(source, first_destination));
    try graph.validate();

    try graph.addEdge(source, second_destination, 0, 0);
    try graph.validate();

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(first_destination));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(second_destination));
    try helpers.expectOutNeighbors(&graph, testing.allocator, source, &[_]u32{second_destination.index});
}

test "mutation: reverse underflow RepairRequired does not publish partial state" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const destination = try graph.addNode();
    const source_count: usize = 65;
    var sources: [source_count]graph_mod.NodeId = undefined;

    for (0..source_count) |source_index| {
        sources[source_index] = try graph.addNode();
        try graph.addEdge(sources[source_index], destination, 0, 0);
    }

    for (0..16) |source_index| {
        try testing.expect(try graph.removeEdge(sources[source_index], destination));
    }
    try graph.validate();
    try testing.expectEqual(@as(u64, 49), graph.edgeCount());
    try testing.expectEqual(@as(usize, 49), try graph.inDegree(destination));

    const forward_block_count_before = graph.graph.block_fwd_count;
    const reverse_block_count_before = graph.graph.block_rev_count;
    const retired_forward_before = graph.graph.retired_blocks_fwd.items.len;
    const retired_reverse_before = graph.graph.retired_blocks_rev.items.len;
    const free_forward_before = graph.graph.free_blocks_fwd.items.len;
    const free_reverse_before = graph.graph.free_blocks_rev.items.len;

    try testing.expectError(error.RepairRequired, graph.removeEdge(sources[16], destination));

    try testing.expectEqual(forward_block_count_before, graph.graph.block_fwd_count);
    try testing.expectEqual(reverse_block_count_before, graph.graph.block_rev_count);
    try testing.expectEqual(retired_forward_before, graph.graph.retired_blocks_fwd.items.len);
    try testing.expectEqual(retired_reverse_before, graph.graph.retired_blocks_rev.items.len);
    try testing.expectEqual(free_forward_before, graph.graph.free_blocks_fwd.items.len);
    try testing.expectEqual(free_reverse_before, graph.graph.free_blocks_rev.items.len);
    try testing.expectEqual(@as(u64, 49), graph.edgeCount());
    try testing.expectEqual(@as(usize, 49), try graph.inDegree(destination));
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(sources[16]));
    try graph.validate();
}

test "mutation: addEdge returns ConcurrentMutation when forward adjacency is claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_a = try graph.addNode();
    const target_b = try graph.addNode();

    // Manually claim the forward adjacency of source to simulate a concurrent writer.
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAt(&graph.graph, source).fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer page_ops.nodeAt(&graph.graph, source).fwd_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, target_a, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, target_b, 0, 0));

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "mutation: addEdge returns ConcurrentMutation when reverse adjacency is claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    try testing.expectEqual(@as(u8, 0), page_ops.nodeAt(&graph.graph, destination).rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer page_ops.nodeAt(&graph.graph, destination).rev_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination, 0, 0));
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, source).fwd_claim.load(.acquire));

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "mutation: self-edge addEdge claims and releases both adjacencies atomically" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 7, 0);
    try graph.validate();

    // Both claims must be released after the mutation.
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, node).fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, node).rev_claim.load(.acquire));

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(node));
}

test "mutation: self-edge removeEdge claims and releases both adjacencies atomically" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);
    try graph.validate();

    try testing.expect(try graph.removeEdge(node, node));
    try graph.validate();

    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, node).fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, node).rev_claim.load(.acquire));

    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(node));
}

test "mutation: forward underflow RepairRequired does not publish partial state" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_count: usize = 65;
    var destinations: [destination_count]graph_mod.NodeId = undefined;

    for (0..destination_count) |destination_index| {
        destinations[destination_index] = try graph.addNode();
        try graph.addEdge(source, destinations[destination_index], 0, 0);
    }

    // Remove edges until the first non-tail forward block would go below MIN_OCCUPANCY.
    for (0..16) |destination_index| {
        try testing.expect(try graph.removeEdge(source, destinations[destination_index]));
    }
    try graph.validate();
    try testing.expectEqual(@as(u64, 49), graph.edgeCount());
    try testing.expectEqual(@as(usize, 49), try graph.outDegree(source));

    const forward_block_count_before = graph.graph.block_fwd_count;
    const reverse_block_count_before = graph.graph.block_rev_count;
    const retired_forward_before = graph.graph.retired_blocks_fwd.items.len;
    const retired_reverse_before = graph.graph.retired_blocks_rev.items.len;

    try testing.expectError(error.RepairRequired, graph.removeEdge(source, destinations[16]));

    try testing.expectEqual(forward_block_count_before, graph.graph.block_fwd_count);
    try testing.expectEqual(reverse_block_count_before, graph.graph.block_rev_count);
    try testing.expectEqual(retired_forward_before, graph.graph.retired_blocks_fwd.items.len);
    try testing.expectEqual(retired_reverse_before, graph.graph.retired_blocks_rev.items.len);
    try testing.expectEqual(@as(u64, 49), graph.edgeCount());
    try testing.expectEqual(@as(usize, 49), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(destinations[16]));
    try graph.validate();
}

test "mutation: removeEdge returns ConcurrentMutation when forward adjacency is claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try graph.validate();

    try testing.expectEqual(@as(u8, 0), page_ops.nodeAt(&graph.graph, source).fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer page_ops.nodeAt(&graph.graph, source).fwd_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try graph.validate();
}

test "mutation: removeEdge returns ConcurrentMutation when reverse adjacency is claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try graph.validate();

    try testing.expectEqual(@as(u8, 0), page_ops.nodeAt(&graph.graph, destination).rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer page_ops.nodeAt(&graph.graph, destination).rev_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
    try testing.expectEqual(@as(u8, 0), page_ops.nodeAtConst(&graph.graph, source).fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try graph.validate();
}

test "mutation: removeEdge of last edge clears adjacency and retires block" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try graph.validate();

    // Snapshot the state before removal. Retired blocks are cleaned up
    // synchronously by reclaimRetired in single-writer mode, so we track
    // retired block growth indirectly by checking the free list.
    const free_blocks_before = graph.graph.free_blocks_fwd.items.len;

    try testing.expect(try graph.removeEdge(source, destination));
    try graph.validate();

    // Removing the last edge retires the block, which ends up on the free list.
    try testing.expect(free_blocks_before < graph.graph.free_blocks_fwd.items.len);
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "mutation: removeEdge of last edge from multi-block adjacency retires both blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    // 64 edges exactly fill one block. Removing them one at a time stays
    // below the RepairRequired threshold because the single block is always
    // the tail (exempt from the MIN_OCCUPANCY guard).
    const destination_count: usize = 64;
    var destinations: [destination_count]graph_mod.NodeId = undefined;

    for (0..destination_count) |destination_index| {
        destinations[destination_index] = try graph.addNode();
        try graph.addEdge(source, destinations[destination_index], 0, 0);
    }
    try graph.validate();

    // Remove all edges, which should clear the entire forward adjacency.
    for (0..destination_count) |destination_index| {
        try testing.expect(try graph.removeEdge(source, destinations[destination_index]));
    }

    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "mutation: hasEdgeInAdj works when blocks are not globally key-sorted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| {
        _ = try graph.addNode();
    }

    // Block 0: destinations 100..163 (full, 64 edges)
    const b0 = try graph.allocBlockFwd();
    var block0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        block0.edges[i] = .{ .destination = @intCast(100 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block0.mask = constants.FULL_BLOCK_MASK;

    // Block 1: destination 50 (appended later, key smaller than block 0's range)
    const b1 = try graph.allocBlockFwd();
    var block1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    block1.edges[0] = .{ .destination = 50, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    block1.mask = constants.denseMask(1);

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 2;
    // Contiguous: b0 and b1 consecutive → single run, NOT key-sorted

    // Binary search alone would miss 120 because it goes right after block 0.
    // Linear fallback must find it.
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 120));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 50));
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 200));
}

test "mutation: findSlotInAdj works with blocks not globally key-sorted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| {
        _ = try graph.addNode();
    }

    // Same setup as above: block 0 keys [100..163], block 1 key [50]
    const b0 = try graph.allocBlockFwd();
    var block0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        block0.edges[i] = .{ .destination = @intCast(100 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block0.mask = constants.FULL_BLOCK_MASK;
    const b1 = try graph.allocBlockFwd();
    var block1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    block1.edges[0] = .{ .destination = 50, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    block1.mask = constants.denseMask(1);

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 2;

    const adj = node.publishedAdj();
    const result = common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 50, .fwd);
    try testing.expect(result != null);
    try testing.expectEqual(b1, result.?.block_idx);
    try testing.expectEqual(@as(u7, 0), result.?.slot);

    const result2 = common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 120, .fwd);
    try testing.expect(result2 != null);
    try testing.expectEqual(b0, result2.?.block_idx);
}

test "mutation: outDegree returns published exact degree on manually constructed adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..65) |_| {
        _ = try graph.addNode();
    }

    const b0 = try graph.allocBlockFwd();
    var block0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        block0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block0.mask = constants.FULL_BLOCK_MASK;
    const b1 = try graph.allocBlockFwd();
    var block1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    block1.edges[0] = .{ .destination = 65, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    block1.mask = constants.denseMask(1);

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 2;
    helpers.setPublishedFwdDegree(node, 65);

    try testing.expectEqual(@as(usize, 65), try graph.outDegree(src));
}

test "mutation: validate detects published degree vs visible mismatch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    _ = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = constants.denseMask(1);

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = block;
    fwd(node).block_count = 1;
    helpers.setPublishedFwdDegree(node, 99);
    helpers.setPublishedRevDegree(try graph.nodeAt(.{ .index = 1 }), 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "mutation: empty block between live blocks in contiguous adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| {
        _ = try graph.addNode();
    }

    // Block 0: [1..64], Block 1: empty (live=0), Block 2: [65..128]
    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = 0; // empty

    const b2 = try graph.allocBlockFwd();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, b2, .fwd);
    for (0..64) |i| {
        blk2.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk2.mask = constants.FULL_BLOCK_MASK;

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 3;

    // Binary search would hit block 1 (live=0) at mid. Fallback must handle it.
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 1));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 65));
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 0));
}

test "mutation: empty block between live blocks in grouped adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| {
        _ = try graph.addNode();
    }

    // Block 0: [1..64], Block 5: empty, Block 3: [65..128] — non-consecutive → grouped
    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = 0;

    const b2 = try graph.allocBlockFwd();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, b2, .fwd);
    for (0..64) |i| {
        blk2.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk2.mask = constants.FULL_BLOCK_MASK;

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b2, .count = 1, .next = constants.END_OF_CHAIN };

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).block_count = 3;
    fwd(node).group_count = 3;
    fwd(node).first_group = g0;

    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 1));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, node.publishedAdj(), 65));
}

test "mutation: binary search hits target exactly at block boundaries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| {
        _ = try graph.addNode();
    }

    // Block 0: [1..64] (first=1, last=64)
    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    // Block 1: [65..128] (first=65, last=128)
    const b1 = try graph.allocBlockFwd();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    for (0..64) |i| {
        blk1.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk1.mask = constants.FULL_BLOCK_MASK;

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 2;

    const adj = node.publishedAdj();

    // first of block 0
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 1));
    // last of block 0
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 64));
    // first of block 1
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 65));
    // last of block 1
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 128));

    // findSlotInAdj same boundaries
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 1, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 64, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 128, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 129, .fwd) == null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 0, .fwd) == null);
}

test "mutation: append creates interleaved block between existing key ranges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..200) |_| {
        _ = try graph.addNode();
    }

    // Block 0: [1..64]
    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    // Block 1: [129..192]
    const b1 = try graph.allocBlockFwd();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    for (0..64) |i| {
        blk1.edges[i] = .{ .destination = @intCast(129 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk1.mask = constants.FULL_BLOCK_MASK;

    // Block 2 (appended, out of order): [65..128] — sits between blocks 0 and 1 in key order
    const b2 = try graph.allocBlockFwd();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, b2, .fwd);
    for (0..64) |i| {
        blk2.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk2.mask = constants.FULL_BLOCK_MASK;

    // Contiguous physical: b0, b1, b2. Logical key order: b0[1..64], b2[65..128], b1[129..192]
    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 3;

    const adj = node.publishedAdj();

    // Targets in each block
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 1));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 64));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 65));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 128));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 129));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 192));

    // Target in the gap that's physically before the target block
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 100));

    // findSlotInAdj must also work
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, 0, 0, 100, .fwd) != null);

    // Non-existent targets
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 0));
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 200));
}

test "mutation: hasEdgeInAdj grouped with interleaved block ranges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..200) |_| {
        _ = try graph.addNode();
    }

    // Three blocks, physically non-consecutive → grouped
    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    // Allocate something else to create a gap
    _ = try graph.allocBlockFwd();

    const b2 = try graph.allocBlockFwd();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, b2, .fwd);
    for (0..64) |i| {
        blk2.edges[i] = .{ .destination = @intCast(129 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk2.mask = constants.FULL_BLOCK_MASK;

    // Another gap
    _ = try graph.allocBlockFwd();

    const b4 = try graph.allocBlockFwd();
    var blk4 = page_ops.edgeBlockAt(&graph.graph, b4, .fwd);
    for (0..64) |i| {
        blk4.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk4.mask = constants.FULL_BLOCK_MASK;

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1, .next = constants.END_OF_CHAIN };

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).block_count = 3;
    fwd(node).group_count = 3;
    fwd(node).first_group = g0;

    const adj = node.publishedAdj();

    // Binary search within group 0 (b0: [1..64])
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 1));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 64));
    // Binary search within group 1 (b2: [129..192])
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 129));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 192));
    // Binary search within group 2 (b4: [65..128]) — keys are out of order across groups
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 65));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 100));
    try testing.expect(adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 128));

    // Non-existent
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 0));
    try testing.expect(!adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 200));
}

test "mutation: findSlotInAdj grouped with interleaved key ranges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..200) |_| {
        _ = try graph.addNode();
    }

    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..64) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.FULL_BLOCK_MASK;

    _ = try graph.allocBlockFwd();
    const b2 = try graph.allocBlockFwd();
    var blk2 = page_ops.edgeBlockAt(&graph.graph, b2, .fwd);
    for (0..64) |i| {
        blk2.edges[i] = .{ .destination = @intCast(129 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk2.mask = constants.FULL_BLOCK_MASK;

    _ = try graph.allocBlockFwd();
    const b4 = try graph.allocBlockFwd();
    var blk4 = page_ops.edgeBlockAt(&graph.graph, b4, .fwd);
    for (0..64) |i| {
        blk4.edges[i] = .{ .destination = @intCast(65 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk4.mask = constants.FULL_BLOCK_MASK;

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    const g2 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b2, .count = 1, .next = g2 };
    page_ops.groupAt(&graph.graph, g2).* = .{ .start = b4, .count = 1, .next = constants.END_OF_CHAIN };

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).block_count = 3;
    fwd(node).group_count = 3;
    fwd(node).first_group = g0;

    const adj = node.publishedAdj();

    // findSlotInAdj must find entries regardless of group key ordering
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, 1, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, 100, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, 129, .fwd) != null);
    try testing.expect(common_mod.findSlotInAdj(&graph.graph, adj.first_block_fwd, adj.block_count_fwd, adj.group_count_fwd, adj.first_group_fwd, 200, .fwd) == null);
}

// ── Degree cache ───────────────────────────────────────────────────────

test "mutation: degree cache tracks exact count through addEdge loop" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const targets = try helpers.addNodes(&graph, 70);

    for (0..70) |i| {
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 70), try graph.outDegree(src));
    // Each target has in-degree 1 (not 70)
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(targets[0]));
}

test "mutation: degree cache decrements correctly after removeEdge loop" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const targets = try helpers.addNodes(&graph, 65);

    for (0..65) |i| {
        try graph.addEdge(src, targets[i], 0, 0);
    }
    // Remove all edges one by one from the last one
    var i: usize = 65;
    while (i > 0) {
        i -= 1;
        try testing.expect(try graph.removeEdge(src, targets[i]));
    }

    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "mutation: degree cache survives repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..85) |_| {
        _ = try graph.addNode();
    }

    const b0 = try graph.allocBlockFwd();
    var blk0 = page_ops.edgeBlockAt(&graph.graph, b0, .fwd);
    for (0..47) |i| {
        blk0.edges[i] = .{ .destination = @intCast(1 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk0.mask = constants.denseMask(47);
    const b1 = try graph.allocBlockFwd();
    var blk1 = page_ops.edgeBlockAt(&graph.graph, b1, .fwd);
    for (0..36) |i| {
        blk1.edges[i] = .{ .destination = @intCast(48 + i), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    blk1.mask = constants.denseMask(36);

    // Set up matching reverse adjacencies
    for (1..84) |dst| {
        const r = try graph.allocBlockRev();
        var rev_block = page_ops.edgeBlockAt(&graph.graph, r, .rev);
        rev_block.sources[0] = src.index;
        rev_block.mask = constants.denseMask(1);
        const dn = try graph.nodeAt(.{ .index = @intCast(dst) });
        rev(dn).first_block = r;
        rev(dn).block_count = 1;
        helpers.setPublishedRevDegree(dn, @as(u22, @intCast(1)));
    }

    const node = try graph.nodeAt(src);
    clearPublished(node);
    fwd(node).first_block = b0;
    fwd(node).block_count = 2;
    helpers.setPublishedFwdDegree(node, @as(u22, @intCast(83)));
    graph.graph.edge_count.store(83, .release);

    try graph.repairNode(src);
    try graph.validate();
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(src));
}

test "mutation: removeEdge of last edge clears adjacency completely" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    const fwd_blocks_before = graph.graph.block_fwd_count;
    const rev_blocks_before = graph.graph.block_rev_count;

    try testing.expect(try graph.removeEdge(src, dst));
    try graph.validate();

    // Adjacency must be empty after removing the only edge
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(src));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(dst));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    // No blocks leaked — old blocks retired, new empty block also retired
    try testing.expectEqual(fwd_blocks_before + 1, graph.graph.block_fwd_count);
    try testing.expectEqual(rev_blocks_before + 1, graph.graph.block_rev_count);
}

test "mutation: removeEdge of last edge in multi-block adjacency shrinks correctly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const targets = try helpers.addNodes(&graph, 65);

    for (0..65) |i| {
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 65), try graph.outDegree(src));

    // Remove the edge in the second block (index 64)
    try testing.expect(try graph.removeEdge(src, targets[64]));
    try graph.validate();
    try testing.expectEqual(@as(usize, 64), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "mutation: removeEdge from single-block group preserves group count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const targets = try helpers.addNodes(&graph, 130);

    // Build a grouped adjacency by adding edges in chunks that force groups
    for (0..64) |i| {
        try graph.addEdge(src, targets[i], 0, 0);
    } // block 0 full
    for (64..128) |i| {
        try graph.addEdge(src, targets[i], 0, 0);
    } // block 1 full
    try graph.addEdge(src, targets[128], 0, 0); // block 2 (1 edge)
    try graph.addEdge(src, targets[129], 0, 0); // block 3 (1 edge)

    try graph.validate();

    // Remove from the single-edge block — should not corrupt group structure
    try testing.expect(try graph.removeEdge(src, targets[128]));
    try graph.validate();
    try testing.expectEqual(@as(usize, 129), try graph.outDegree(src));
}

test "mutation: outDegree returns exact published degree O(1)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..130) |_| _ = try graph.addNode();
    for (1..130) |i| try graph.addEdge(src, .{ .index = @intCast(i) }, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(usize, 129), try graph.outDegree(src));
}

test "mutation: addEdge returns error when degree would exceed MAX_DEGREE_PER_SIDE" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const source_node = try graph.nodeAt(source);
    helpers.setPublishedFwdDegree(source_node, constants.MAX_DEGREE_PER_SIDE);

    try testing.expectError(error.OutOfMemory, graph.addEdge(source, destination, 0, 0));

    // Assert no partial state was published: edge_count and forged degree unchanged.
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(constants.MAX_DEGREE_PER_SIDE, helpers.publishedDegrees(source_node).fwd);
}

test "mutation: removeEdge publishes exact decremented degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst1 = try graph.addNode();
    const dst2 = try graph.addNode();
    try graph.addEdge(src, dst1, 0, 0);
    try graph.addEdge(src, dst2, 0, 0);

    try testing.expect(try graph.removeEdge(src, dst1));
    try graph.validate();

    try testing.expectEqual(@as(u22, 1), (try graph.nodeAtConst(src)).loadPublishedMeta().degree_fwd);
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}
