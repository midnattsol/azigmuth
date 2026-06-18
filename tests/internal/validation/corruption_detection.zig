const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const testing = std.testing;

fn containsViolation(violations: []const types.Violation, comptime tag: std.meta.Tag(types.Violation)) bool {
    for (violations) |violation| {
        if (std.meta.activeTag(violation) == tag) return true;
    }
    return false;
}

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn publishForwardBlock(graph: *graph_mod.Graph, node: graph_mod.NodeId, block_idx: u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = block_idx;
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    try publish.syncToPublished(graph, node.index);
}

fn publishForwardSegments(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_segment: u32,
    block_count: u16,
    segment_count: u16,
) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    publish.publishedFwdSide(node_buffer).segment_count = segment_count;
    publish.publishedFwdSide(node_buffer).first_segment = first_segment;
    try publish.syncToPublished(graph, node.index);
}

test "validation: detects live count beyond block capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const target = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.destinations[0] = target.index;
    edges.relations[0] = 0;
    edges.flags[0] = 0;
    // Corrupt: live count beyond block capacity.
    page_ops.blockAliveCountPtr(&graph.graph, block, .fwd).* = 65;
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .mask_bit_out_of_range));
}

test "validation: detects invalid destinations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.destinations[0] = 999;
    edges.relations[0] = 0;
    edges.flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(1));
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .invalid_destination));
}

test "validation: detects unsorted blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 3);
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.destinations[0] = 2;
    edges.relations[0] = 0;
    edges.flags[0] = 0;
    edges.destinations[1] = 1;
    edges.relations[1] = 0;
    edges.flags[1] = 0;
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(2));
    try publishForwardBlock(&graph, .{ .index = 0 }, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .unsorted_block));
}

test "validation: multigraph detects reverse multiplicity mismatch" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try graph.addEdge(source, destination, 1, 0);

    const destination_adj = try graph.publishedNodeAdj(destination);
    try publish.truncateReverseByOne(&graph, destination, destination_adj);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .forward_reverse_multiplicity_mismatch) or
        containsViolation(violations, .forward_reverse_count_mismatch));
}

test "validation: multigraph detects zero edge id in sidecar" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.addEdgeWithId(source, destination, 0, 0);

    const source_adj = graph.nodeRefAny(source).publishedAdj();
    try publish.writeForwardEdgeId(&graph, source_adj, 0, 0);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .invalid_edge_id));
}

test "validation: multigraph detects duplicate edge id within one source" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_a = try graph.addNode();
    const destination_b = try graph.addNode();
    const id_a = try graph.addEdgeWithId(source, destination_a, 0, 0);
    _ = try graph.addEdgeWithId(source, destination_b, 0, 0);

    const source_adj = graph.nodeRefAny(source).publishedAdj();
    try publish.writeForwardEdgeId(&graph, source_adj, 1, id_a.local);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .duplicate_edge_id));
}

test "validation: multigraph detects regressed next edge id counter" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.addEdgeWithId(source, destination, 0, 0);

    page_ops.nodeMutationControlAt(&graph.graph, source).storeNextLocalEdgeId(1);
    page_ops.nodeMutationControlAt(&graph.graph, source).storeNextLocalEdgeId(1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .edge_id_counter_regressed));
}

test "validation: multigraph detects descending edge ids for equal destination" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const first_id = try graph.addEdgeWithId(source, destination, 0, 0);
    const second_id = try graph.addEdgeWithId(source, destination, 1, 0);

    const source_adj = graph.nodeRefAny(source).publishedAdj();
    try publish.writeForwardEdgeId(&graph, source_adj, 0, second_id.local);
    try publish.writeForwardEdgeId(&graph, source_adj, 1, first_id.local);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}

test "validation: detects global edge count mismatch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = [_]graph_mod.NodeId{ try graph.addNode(), try graph.addNode() };
    try graph.addEdge(nodes[0], nodes[1], 0, 0);
    graph.graph.edge_count.store(7, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .edge_count_mismatch));
}

test "validation: detects underfull non-tail blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 60);
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();

    var first_edges = page_ops.edgeBlockAt(&graph.graph, first_block, .fwd);
    for (0..47) |edge_idx| {
        first_edges.destinations[edge_idx] = @intCast(edge_idx + 1);
        first_edges.relations[edge_idx] = 0;
        first_edges.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, first_block, .fwd, 47);

    var second_edges = page_ops.edgeBlockAt(&graph.graph, second_block, .fwd);
    second_edges.destinations[0] = 48;
    second_edges.relations[0] = 0;
    second_edges.flags[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, second_block, .fwd, 1);

    try publishForwardBlock(&graph, .{ .index = 0 }, first_block, 2);
    graph.graph.edge_count.store(48, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .occupancy_below_threshold));
}

test "validation: detects segmented slot_entry declared past allocated segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const segment = try graph.allocSegment();

    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);
    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{ .start = block, .count = 1 };
    try publishForwardSegments(&graph, node, segment, 1, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blocksegment_chain_cycle));
}

test "validation: detects overlapping block segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const segment0 = try graph.allocSegment();
    const segment1 = try graph.allocSegment();

    page_ops.edgeBlockSegmentAt(&graph.graph, segment0).* = .{ .start = block0, .count = 2 };
    page_ops.edgeBlockSegmentAt(&graph.graph, segment1).* = .{ .start = block0 + 1, .count = 1 };
    try publishForwardSegments(&graph, node, segment0, 3, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blocksegment_overlap));
}

test "validation: detects double-owned blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node0 = try graph.addNode();
    const node1 = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);

    try publishForwardBlock(&graph, node0, block, 1);
    try publishForwardBlock(&graph, node1, block, 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_double_owned));
}

test "validation: detects owned blocks present in free list" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);
    try publishForwardBlock(&graph, node, block, 1);
    page_ops.freeBlock(&graph.graph, block, .fwd);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_orphaned_in_free_list));
}

test "validation: detects retired blocks still reachable" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, 0);
    try publishForwardBlock(&graph, node, block, 1);
    try graph.retireBlockFwd(block);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .retired_block_reachable));
}

test "validation: detects invalid repair debt entries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    try graph.graph.repair_fwd.append(graph.graph.allocator, 123);
    try graph.graph.repair_rev.append(graph.graph.allocator, 456);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .repair_debt_invalid_node));
}

test "validation: segmented block_count mismatch vs sum of segment.count is detected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 5);

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    fillBlockWithDestinations(&graph, b0, 1, 1);
    fillBlockWithDestinations(&graph, b1, 2, 1);

    const g0 = try graph.allocSegment();
    // Single segment covering 2 physically contiguous blocks.
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = b0, .count = 2 };

    // Reverse adjacency for both destinations so forward/reverse consistency passes.
    const rb0 = try graph.allocBlockRev();
    const rb1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, rb0, .rev).sources[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, rb0, .rev, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, rb1, .rev).sources[0] = 0;
    page_ops.setBlockAliveCount(&graph.graph, rb1, .rev, @intCast(1));
    {
        const d1 = try graph.nodeAt(.{ .index = 1 });
        publish.clearPublishedSides(d1);
        publish.publishedRevSide(d1).first_block = rb0;
        publish.publishedRevSide(d1).block_count = 1;
        publish.setPublishedRevDegree(d1, @as(u22, @intCast(1)));
    }
    {
        const d2 = try graph.nodeAt(.{ .index = 2 });
        publish.clearPublishedSides(d2);
        publish.publishedRevSide(d2).first_block = rb1;
        publish.publishedRevSide(d2).block_count = 1;
        publish.setPublishedRevDegree(d2, @as(u22, @intCast(1)));
    }

    const node = try graph.nodeAt(.{ .index = 0 });
    publish.clearPublishedSides(node);
    // block_count says 1, but the chain segment_descriptors 2 blocks.
    publish.publishedFwdSide(node).first_block = b0;
    publish.publishedFwdSide(node).block_count = 1;
    publish.publishedFwdSide(node).segment_count = 1;
    publish.publishedFwdSide(node).first_segment = g0;
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(2)));
    graph.graph.edge_count.store(2, .release);

    // validate() must now detect this mismatch.
    try testing.expectError(error.CorruptGraph, graph.validate());
}

fn fillBlockWithDestinations(graph: *graph_mod.Graph, block_idx: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    for (0..count) |slot_idx| {
        block.destinations[slot_idx] = first_destination + @as(u32, @intCast(slot_idx));
        block.relations[slot_idx] = 0;
        block.flags[slot_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .fwd, @intCast(count));
}

test "validation: removed node entry in repair queue is currently accepted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(target);

    try graph.graph.repair_fwd.append(graph.graph.allocator, target.index);

    // Current semantics: validate does not reject in-range-but-removed queue entries.
    try graph.validate();

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!containsViolation(violations, .repair_debt_invalid_node));
}

test "validation: detects published exact degree mismatch on forward side" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    // Corrupt the published forward degree — it should match the visible count.
    publish.setPublishedFwdDegree(try graph.nodeAt(source), 999);
    publish.syncPublicationStateToPublished(&graph, source.index);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "validation: detects published exact degree mismatch on reverse side" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    publish.setPublishedRevDegree(try graph.nodeAt(target), 999);
    publish.syncPublicationStateToPublished(&graph, target.index);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .degree_mismatch));
}

test "validation: detects predecessor with tombstone but missing needs_repair_fwd flag" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    // removeNode(target) marks target removed and sets needs_repair_fwd on source.
    _ = try graph.removeNode(target);
    try graph.validate(); // state is clean after removeNode

    // Manually clear the needs_repair_fwd flag on source while the tombstoned
    // forward reference to target still persists in source's blocks.
    // Invariant: a live predecessor with a tombstoned forward ref MUST
    // have needs_repair_fwd set.  Clearing it creates a hidden invariant violation.
    var source_node = try graph.nodeAt(source);
    {
        var flags = source_node.loadPublicationState().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }
    publish.syncPublicationStateToPublished(&graph, source.index);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}

test "validation: debugValidate reports missing needs_repair_fwd on predecessor with tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    _ = try graph.removeNode(target);

    var source_node = try graph.nodeAt(source);
    {
        var flags = source_node.loadPublicationState().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }
    publish.syncPublicationStateToPublished(&graph, source.index);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}

test "validation: destination reverse residual does not imply reverse tombstone debt after removeNode(source)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeNode(source);
    try graph.validate();

    const destination_adj = try graph.publishedNodeAdj(destination);
    try testing.expect(destination_adj.block_count_rev > 0);
    try testing.expect(destination_adj.flags.needs_repair_rev);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!containsViolation(violations, .reverse_tombstone_missing_repair_flag));
}

test "validation: debugValidate does not report reverse tombstone debt after removeNode(source)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeNode(source);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(!containsViolation(violations, .reverse_tombstone_missing_repair_flag));
}

test "validation: removed node with non-zero published degree is flagged" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(target);

    // Removed nodes must have published degree 0 on both sides.
    const node = graph.nodeRefAny(target);
    publish.setPublishedRevDegree(node, 1);
    publish.syncPublicationStateToPublished(&graph, target.index);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "validation: debugValidate survives invalid first_segment" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = 1;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
    try publishForwardSegments(&graph, node, 0xFF_FFFF, 1, 1);
    graph.graph.edge_count.store(1, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blocksegment_chain_cycle));
}

test "validation: debugValidate continues after malformed segment slot_entry with later inconsistency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 3);
    const node = graph_mod.NodeId{ .index = 0 };
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = 1;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
    const segment = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, segment).* = .{ .start = block, .count = 1 };
    try publishForwardSegments(&graph, node, segment, 1, 2);

    graph.graph.edge_count.store(2, .release);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blocksegment_chain_cycle));
    try testing.expect(containsViolation(violations, .edge_count_mismatch));
}

test "validation: validate returns CorruptGraph for invalid first_segment" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.setBlockAliveCount(&graph.graph, block, .fwd, @intCast(1));
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).destinations[0] = 1;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).relations[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).flags[0] = 0;
    try publishForwardSegments(&graph, node, 0xFF_FFFF, 1, 1);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "validation: removed node with reverse structural storage is corruption" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, removed_target, 0, 0);
    _ = try graph.removeNode(removed_target);
    try graph.validate();

    // Corrupt: re-inject a structural reverse block on the removed node while
    // its published reverse degree stays zero. removeNode guarantees both
    // descriptors are cleared synchronously, so this must be flagged.
    const block = try graph.allocBlockRev();
    const node_buffer = graph.nodeRefAny(removed_target);
    publish.publishedRevSide(node_buffer).first_block = block;
    publish.publishedRevSide(node_buffer).block_count = 1;
    try publish.syncToPublished(&graph, removed_target.index);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .removed_node_has_reverse_storage));
}

test "validation: snapshot capture does not elide zero-degree side headers" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.addNode();

    // Corrupt: forward side header points at one block while the published
    // degree stays zero. The capture must surface the header so snapshot
    // validation can see the inconsistency instead of an invented empty side.
    const block = try graph.allocBlockFwd();
    try publishForwardBlock(&graph, node, block, 1);

    var view = try graph_mod.snapshot_view_mod.captureGraphView(&graph.graph, testing.allocator);
    defer view.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), view.fwd_block_count[node.index]);
    try testing.expectEqual(@as(u32, 0), view.degree_fwd[node.index]);
}
