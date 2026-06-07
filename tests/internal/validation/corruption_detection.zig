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

fn publishForwardBlock(graph: *graph_mod.Graph, node: graph_mod.NodeId, block_index: u32, block_count: u16) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = block_index;
    publish.publishedFwdSide(node_buffer).block_count = block_count;
}

fn publishForwardGroups(
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    first_group: u32,
    block_count: u16,
    group_count: u16,
) !void {
    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).block_count = block_count;
    publish.publishedFwdSide(node_buffer).group_count = group_count;
    publish.publishedFwdSide(node_buffer).first_group = first_group;
}

test "validation: detects non-dense masks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const target = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.edges[2] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = 0b101;
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .mask_bit_out_of_range));
}

test "validation: detects invalid destinations" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = 999, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = constants.denseMask(1);
    try publishForwardBlock(&graph, node, block, 1);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .invalid_dst));
}

test "validation: detects unsorted blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 3);
    const block = try graph.allocBlockFwd();
    var edges = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    edges.edges[0] = .{ .destination = 2, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.edges[1] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    edges.mask = constants.denseMask(2);
    try publishForwardBlock(&graph, .{ .index = 0 }, block, 1);
    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
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

    const destination_adj = (try graph.nodeAt(destination)).publishedAdj();
    const reverse_block = page_ops.edgeBlockAt(&graph.graph, destination_adj.first_block_rev, .rev);
    reverse_block.mask = constants.denseMask(1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .forward_reverse_multiplicity_mismatch));
}

test "validation: multigraph detects zero edge id in sidecar" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.addEdgeWithId(source, destination, 0, 0);

    const source_adj = (try graph.nodeAt(source)).publishedAdj();
    page_ops.edgeBlockFwdIdsAt(&graph.graph, source_adj.first_block_fwd).ids[0] = 0;

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
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

    const source_adj = (try graph.nodeAt(source)).publishedAdj();
    const id_block = page_ops.edgeBlockFwdIdsAt(&graph.graph, source_adj.first_block_fwd);
    id_block.ids[1] = id_a.local;

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .duplicate_edge_id));
}

test "validation: multigraph detects regressed next edge id counter" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    _ = try graph.addEdgeWithId(source, destination, 0, 0);

    const source_node = try graph.nodeAt(source);
    source_node.next_local_edge_id.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
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

    const source_adj = (try graph.nodeAt(source)).publishedAdj();
    const id_block = page_ops.edgeBlockFwdIdsAt(&graph.graph, source_adj.first_block_fwd);
    id_block.ids[0] = second_id.local;
    id_block.ids[1] = first_id.local;

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .unsorted_block));
}

test "validation: detects global edge count mismatch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes = [_]graph_mod.NodeId{ try graph.addNode(), try graph.addNode() };
    try graph.addEdge(nodes[0], nodes[1], 0, 0);
    graph.graph.edge_count.store(7, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
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
    for (0..47) |edge_index| {
        first_edges.edges[edge_index] = .{ .destination = @intCast(edge_index + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_edges.mask = constants.denseMask(47);

    var second_edges = page_ops.edgeBlockAt(&graph.graph, second_block, .fwd);
    second_edges.edges[0] = .{ .destination = 48, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    second_edges.mask = constants.denseMask(1);

    try publishForwardBlock(&graph, .{ .index = 0 }, first_block, 2);
    graph.graph.edge_count.store(48, .release);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .occupancy_below_threshold));
}

test "validation: detects grouped span declared past allocated runs" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    const group = try graph.allocGroup();

    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = constants.END_OF_CHAIN };
    try publishForwardGroups(&graph, node, group, 1, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_chain_cycle));
}

test "validation: detects overlapping block groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block0 = try graph.allocBlockFwd();
    _ = try graph.allocBlockFwd();
    const group0 = try graph.allocGroup();
    const group1 = try graph.allocGroup();

    page_ops.groupAt(&graph.graph, group0).* = .{ .start = block0, .count = 2, .next = group1 };
    page_ops.groupAt(&graph.graph, group1).* = .{ .start = block0 + 1, .count = 1, .next = constants.END_OF_CHAIN };
    try publishForwardGroups(&graph, node, group0, 3, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_overlap));
}

test "validation: detects double-owned blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node0 = try graph.addNode();
    const node1 = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;

    try publishForwardBlock(&graph, node0, block, 1);
    try publishForwardBlock(&graph, node1, block, 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_double_owned));
}

test "validation: detects owned blocks present in free list" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    try publishForwardBlock(&graph, node, block, 1);
    page_ops.freeBlock(&graph.graph, block, .fwd);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .block_orphaned_in_free_list));
}

test "validation: detects retired blocks still reachable" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = 0;
    try publishForwardBlock(&graph, node, block, 1);
    try graph.retireBlockFwd(block);

    try testing.expectError(error.CorruptGraph, graph.validate());
    const violations = try graph.debugValidate(testing.allocator);
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
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .repair_debt_invalid_node));
}

test "validation: grouped block_count mismatch vs sum of group.count is detected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 5);

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    fillBlockWithDst(&graph, b0, 1, 1);
    fillBlockWithDst(&graph, b1, 2, 1);

    const g0 = try graph.allocGroup();
    // Single group covering 2 physically contiguous blocks.
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 2, .next = constants.END_OF_CHAIN };

    // Reverse adjacency for both destinations so forward/reverse consistency passes.
    const rb0 = try graph.allocBlockRev();
    const rb1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, rb0, .rev).sources[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, rb0, .rev).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, rb1, .rev).sources[0] = 0;
    page_ops.edgeBlockAt(&graph.graph, rb1, .rev).mask = constants.denseMask(1);
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
    // block_count says 1, but the chain spans 2 blocks.
    publish.publishedFwdSide(node).first_block = b0;
    publish.publishedFwdSide(node).block_count = 1;
    publish.publishedFwdSide(node).group_count = 1;
    publish.publishedFwdSide(node).first_group = g0;
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(2)));
    graph.graph.edge_count.store(2, .release);

    // validate() must now detect this mismatch.
    try testing.expectError(error.CorruptGraph, graph.validate());
}

fn fillBlockWithDst(graph: *graph_mod.Graph, block_index: u32, first_dst: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |i| {
        block.edges[i] = .{ .destination = first_dst + @as(u32, @intCast(i)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
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

    const violations = try graph.debugValidate(testing.allocator);
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

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "validation: detects published exact degree mismatch on reverse side" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    publish.setPublishedRevDegree(try graph.nodeAt(target), 999);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(testing.allocator);
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
    // RFC §3.2 & §6.3: a live predecessor with a tombstoned forward ref MUST
    // have needs_repair_fwd set.  Clearing it creates a hidden invariant violation.
    var source_node = try graph.nodeAt(source);
    {
        var flags = source_node.loadPublishedMeta().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(testing.allocator);
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
        var flags = source_node.loadPublishedMeta().flags();
        flags.needs_repair_fwd = false;
        publish.setPublishedFlags(source_node, flags);
    }

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}

test "validation: detects destination with reverse tombstone but missing needs_repair_rev flag" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeNode(source);
    try graph.validate();

    var destination_node = try graph.nodeAt(destination);
    {
        var flags = destination_node.loadPublishedMeta().flags();
        flags.needs_repair_rev = false;
        publish.setPublishedFlags(destination_node, flags);
    }

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .reverse_tombstone_missing_repair_flag));
}

test "validation: debugValidate reports missing needs_repair_rev on destination with reverse tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    _ = try graph.removeNode(source);

    var destination_node = try graph.nodeAt(destination);
    {
        var flags = destination_node.loadPublishedMeta().flags();
        flags.needs_repair_rev = false;
        publish.setPublishedFlags(destination_node, flags);
    }

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .reverse_tombstone_missing_repair_flag));
}

test "validation: removed node with non-zero published degree is flagged" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(target);

    // Removed nodes must have published degree 0 on both sides.
    const node = page_ops.nodeAt(&graph.graph, target);
    publish.setPublishedRevDegree(node, 1);

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "validation: debugValidate survives invalid first_group" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).edges[0] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    try publishForwardGroups(&graph, node, 0xFF_FFFF, 1, 1);
    graph.graph.edge_count.store(1, .release);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_chain_cycle));
}

test "validation: debugValidate continues after malformed group.next with later inconsistency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try addNodeCount(&graph, 3);
    const node = graph_mod.NodeId{ .index = 0 };
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).edges[0] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    const group = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, group).* = .{ .start = block, .count = 1, .next = 0xFF_FFFF };
    try publishForwardGroups(&graph, node, group, 1, 2);

    graph.graph.edge_count.store(2, .release);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(containsViolation(violations, .blockgroup_chain_cycle));
    try testing.expect(containsViolation(violations, .edge_count_mismatch));
}

test "validation: validate returns CorruptGraph for invalid first_group" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.addNode();
    const block = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, block, .fwd).edges[0] = .{ .destination = 1, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    try publishForwardGroups(&graph, node, 0xFF_FFFF, 1, 1);
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());
}
