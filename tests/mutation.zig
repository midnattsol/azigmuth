const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const types = test_internals.types;
const helpers = @import("helpers.zig");

const testing = std.testing;

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

    var source_node = try graph.nodeAt(source);
    source_node.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    source_node.adj_buffers[0].first_block_fwd = forward_block;
    source_node.adj_buffers[0].block_count_fwd = 1;
    source_node.storePublishedAdjIndex(0);
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

    var destination_node = try graph.nodeAt(destination);
    destination_node.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    destination_node.adj_buffers[0].first_block_rev = reverse_block;
    destination_node.adj_buffers[0].block_count_rev = 1;
    destination_node.storePublishedAdjIndex(0);

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
