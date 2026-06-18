//! Tests that corrupt edge-block segment segment_descriptors are detected by validate() and do NOT
//! hang mutation/query APIs.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

fn makeAdjacencySegmentedWithInvalidDeclaredSlots(graph: *graph_mod.Graph, node: graph_mod.NodeId) !void {
    var published_adj = (try graph.nodeAt(node)).publishedAdj();
    if (published_adj.block_count_fwd == 0) return error.SkipZigTest;

    published_adj = try publish.ensureForwardBlockLayout(graph, node);

    const existing_blocks = published_adj.block_count_fwd;
    const existing_segments = published_adj.segment_count_fwd;

    if (existing_segments == 0) {
        const g0 = try graph.allocSegment();
        page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{
            .start = published_adj.first_block_fwd,
            .count = existing_blocks,
        };
        const buf = try graph.nodeAt(node);
        publish.publishedFwdSide(buf).segment_count = 2;
        publish.publishedFwdSide(buf).first_segment = g0;
    } else {
        const buf = try graph.nodeAt(node);
        publish.publishedFwdSide(buf).segment_count += 1;
    }

    try publish.syncToPublished(graph, node.index);
}

test "segment chain: validate detects cyclic forward segment chain on contiguous adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);
    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "segment chain: validate detects cyclic forward segment chain on already-segmented adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..65) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, 0);
    }

    const buf = try graph.nodeAt(source);
    publish.publishedFwdSide(buf).segment_count += 1;
    try publish.syncToPublished(&graph, source.index);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "segment chain: hasEdgeInAdj on cyclic chain with absent target does not hang" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const absent = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    // absent is not an edge destination — the cyclic scan should terminate
    // via bounded traversal and return false without hanging.
    try testing.expect(!graph.hasEdgeInAdj((try graph.nodeAt(source)).publishedAdj(), absent.index));
}

test "segment chain: tailBlockIndex on cyclic chain returns null (does not hang)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    const adj = (try graph.nodeAt(source)).publishedAdj();
    if (adj.segment_count_fwd > 0) {
        const side_adj = (try graph.nodeAt(source)).publishedFwd();
        try testing.expect(graph_mod.adjacency_mod.tailBlockIndexSide(&graph.graph, &side_adj) == null);
    }
}

test "contiguous layout: neighbors rejects first_block outside allocated range" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const buf = try graph.nodeAt(source);
    publish.clearPublishedSides(buf);
    publish.publishedFwdSide(buf).first_block = graph.graph.block_fwd_count + 1;
    publish.publishedFwdSide(buf).block_count = 1;
    publish.setPublishedFwdDegree(buf, 1);
    try publish.syncToPublished(&graph, source.index);

    try testing.expectError(error.CorruptGraph, graph.neighbors(source));
}

test "segment chain: neighbors on cyclic chain does not hang" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    try testing.expect(iterator.next() != null);
    try testing.expect(iterator.next() == null);
}

test "segment chain: neighbors on cyclic chain remains bounded" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    var count: usize = 0;
    while (iterator.next() != null) : (count += 1) {}
    try testing.expectEqual(@as(usize, 1), count);
}

test "segment chain: repairNode on cyclic forward chain returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);
    {
        const buf = try graph.nodeAt(source);
        publish.setPublishedFlags(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
        try publish.syncToPublished(&graph, source.index);
    }

    try testing.expectError(error.CorruptGraph, graph.repairNode(source));
}

test "segment chain: repairBudgeted on cyclic chain returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);
    {
        const buf = try graph.nodeAt(source);
        publish.setPublishedFlags(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
        try publish.syncToPublished(&graph, source.index);
    }
    try graph.graph.repair_fwd.append(graph.graph.allocator, source.index);

    try testing.expectError(error.CorruptGraph, graph.repairBudgeted(1));
}

test "segment chain: removeEdge on cyclic segmented forward adjacency returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    // The edge against 'destination' still structurally exists.  removeEdge
    // finds it (lookup is bounded), but the segmented-chain rebuild
    // (applyRemovalPlanSide → rebuildAdjWithReplaceSide) is unbounded.
    try testing.expectError(error.CorruptGraph, graph.removeEdge(source, destination));
}

test "segment chain: validate does not hang on cyclic chain with forward tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const removed = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    // Insert a tombstone entry pointing to the removed node into source's forward.
    const source_node = try graph.nodeAt(source);
    const published_fwd = source_node.publishedFwd();
    if (published_fwd.block_count > 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, published_fwd.first_block, .fwd);
        const alive: u7 = @intCast(page_ops.blockAliveCount(&graph.graph, published_fwd.first_block, .fwd));
        // Overwrite the first entry to point to the removed node.
        if (alive > 0) {
            block.destinations[0] = removed.index;
        }
    }

    // Mark the target node as removed so the edge becomes a tombstone.
    {
        const removed_buf = try graph.nodeAt(removed);
        var state = removed_buf.loadPublicationState();
        state.removed = true;
        removed_buf.storePublicationState(state);
    }

    // Set needs_repair_fwd = false to force forwardHasTombstone path.
    {
        var flags = source_node.loadPublicationState().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }

    // validate() must not hang — must either return CorruptGraph or succeed.
    _ = graph.validate() catch {};

    // debugValidate must also terminate.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    // Must emit either forward_tombstone_missing_repair_flag or a cyclic chain violation.
    var found = false;
    for (violations) |violation| {
        if (violation == .forward_tombstone_missing_repair_flag or
            violation == .blocksegment_chain_cycle)
        {
            found = true;
        }
    }
    try testing.expect(found);
}

test "segment chain: debugValidate terminates on cyclic chain with tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const removed = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try makeAdjacencySegmentedWithInvalidDeclaredSlots(&graph, source);

    const source_node = try graph.nodeAt(source);
    const published_fwd = source_node.publishedFwd();
    if (published_fwd.block_count > 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, published_fwd.first_block, .fwd);
        const alive: u7 = @intCast(page_ops.blockAliveCount(&graph.graph, published_fwd.first_block, .fwd));
        if (alive > 0) {
            block.destinations[0] = removed.index;
        }
    }

    {
        const removed_buf = try graph.nodeAt(removed);
        var state = removed_buf.loadPublicationState();
        state.removed = true;
        removed_buf.storePublicationState(state);
    }

    {
        var flags = source_node.loadPublicationState().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }

    // debugValidate must terminate quickly.
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
