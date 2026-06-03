const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const types = test_internals.types;
const helpers = @import("helpers.zig");
const testing = std.testing;

test "regression: removeNode reverse-only publish does not flip forward index of related nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const fwd_index_before = b_node.loadPublishedMeta().fwd_index;

    try graph.removeNode(a);

    const fwd_index_after = b_node.loadPublishedMeta().fwd_index;
    try testing.expectEqual(fwd_index_before, fwd_index_after);
    try graph.validate();
}

test "regression: removeNode returns CorruptGraph when reverse backlink is missing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();

    // Remove the reverse entry for A manually, making forward/reverse inconsistent.
    if (b_adj.block_count_rev > 0 and b_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        var found = false;
        for (0..live) |slot| {
            if (block.sources[slot] == a.index) {
                // Overwrite with a value > node_count so it looks "live" but wrong
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: removeNode returns CorruptGraph when reverse backlink is duplicated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const b_node = try graph.nodeAt(b);
    const b_adj = b_node.publishedAdj();

    // Find a slot that doesn't contain A and overwrite it with A, creating a duplicate.
    if (b_adj.block_count_rev > 0 and b_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, b_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = a.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: validate and debugValidate agree on removed node with residual reverse" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const spoke_count: usize = 10;
    var spokes: [spoke_count]graph_mod.NodeId = undefined;
    for (0..spoke_count) |i| {
        spokes[i] = try graph.addNode();
        try graph.addEdge(spokes[i], hub, 0, 0);
    }

    // Remove half the spokes, leaving tombstones in hub's reverse adjacency.
    for (0..spoke_count) |i| {
        if (i % 2 == 0) try graph.removeNode(spokes[i]);
    }

    // Both validators must pass.
    try graph.validate();
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "regression: removeNode returns CorruptGraph when incoming reverse backlink is missing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0); // b -> a

    // Corrupt a's incoming reverse adjacency: overwrite b's entry so
    // reverse(a) no longer references b, but forward(b) still
    // references a — a forward/reverse mismatch.
    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_rev > 0 and a_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        var found = false;
        for (0..live) |slot| {
            if (block.sources[slot] == b.index) {
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: removeNode returns CorruptGraph when incoming reverse backlink is duplicated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(b, a, 0, 0); // b -> a

    // Duplicate b in a's incoming reverse adjacency so reverse(a)
    // contains b twice while forward(b) only references a once.
    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_rev > 0 and a_adj.group_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_rev, .rev);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.sources[live] = b.index;
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: removeNode returns CorruptGraph when outgoing forward destination is duplicated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0); // a -> b

    // Corrupt forward(a): duplicate destination b without touching reverse(b).
    const a_adj = page_ops.nodeAt(&graph.graph, a).publishedAdj();
    if (a_adj.block_count_fwd > 0 and a_adj.group_count_fwd == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, a_adj.first_block_fwd, .fwd);
        const live = @popCount(block.mask);
        if (live < 64) {
            block.edges[live] = block.edges[live - 1]; // duplicate b
            block.mask = constants.denseMask(@intCast(live + 1));
        }
    }

    // RFC §A.25: removeNode MUST validate the local forward/reverse bijection
    // without a full-graph scan.  A duplicated outgoing destination breaks that
    // bijection and must be rejected.
    try testing.expectError(error.CorruptGraph, graph.removeNode(a));
}

test "regression: removeNode returns CorruptGraph when grouped forward chain is shorter than declared group count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const dest_a = try graph.addNode();
    const dest_b = try graph.addNode();

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).edges[0] = .{ .destination = dest_a.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).edges[0] = .{ .destination = dest_b.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = constants.END_OF_CHAIN };

    const source_node = try graph.nodeAt(source);
    helpers.clearPublishedSides(source_node);
    helpers.publishedFwdSide(source_node).block_count = 2;
    helpers.publishedFwdSide(source_node).group_count = 2;
    helpers.publishedFwdSide(source_node).first_group = g0;
    helpers.setPublishedFwdDegree(source_node, 2);

    // Truncate the chain: g0.next = END while group_count still says 2.
    page_ops.groupAt(&graph.graph, g0).next = constants.END_OF_CHAIN;

    // Reverse backlinks: each destination has source in its reverse.
    {
        const b = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, b, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, b, .rev).mask = constants.denseMask(1);
        const dn = try graph.nodeAt(dest_a);
        helpers.clearPublishedSides(dn);
        helpers.publishedRevSide(dn).first_block = b;
        helpers.publishedRevSide(dn).block_count = 1;
        helpers.setPublishedRevDegree(dn, 1);
    }
    {
        const b = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, b, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, b, .rev).mask = constants.denseMask(1);
        const dn = try graph.nodeAt(dest_b);
        helpers.clearPublishedSides(dn);
        helpers.publishedRevSide(dn).first_block = b;
        helpers.publishedRevSide(dn).block_count = 1;
        helpers.setPublishedRevDegree(dn, 1);
    }

    graph.graph.edge_count.store(2, .release);

    // Broken forward chain: removeNode must not publish a partial delete.
    try testing.expectError(error.CorruptGraph, graph.removeNode(source));

    // Verify dest_b's reverse was not touched (removeNode must abort before publish).
    try testing.expectEqual(@as(u22, 1), helpers.publishedDegrees(try graph.nodeAt(dest_b)).rev);
}

test "regression: removeNode returns CorruptGraph when grouped forward chain is shorter with live destination skipped" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const dest_a = try graph.addNode();
    const dest_b = try graph.addNode();

    const b0 = try graph.allocBlockFwd();
    const b1 = try graph.allocBlockFwd();
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).edges[0] = .{ .destination = dest_a.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).edges[0] = .{ .destination = dest_b.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    page_ops.edgeBlockAt(&graph.graph, b1, .fwd).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = b1, .count = 1, .next = constants.END_OF_CHAIN };

    const source_node = try graph.nodeAt(source);
    helpers.clearPublishedSides(source_node);
    helpers.publishedFwdSide(source_node).block_count = 2;
    helpers.publishedFwdSide(source_node).group_count = 2;
    helpers.publishedFwdSide(source_node).first_group = g0;
    helpers.setPublishedFwdDegree(source_node, 2);

    // Truncate chain: dest_b's block data exists but is unreachable.
    page_ops.groupAt(&graph.graph, g0).next = constants.END_OF_CHAIN;

    {
        const b = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, b, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, b, .rev).mask = constants.denseMask(1);
        const dn = try graph.nodeAt(dest_a);
        helpers.clearPublishedSides(dn);
        helpers.publishedRevSide(dn).first_block = b;
        helpers.publishedRevSide(dn).block_count = 1;
        helpers.setPublishedRevDegree(dn, 1);
    }
    {
        const b = try graph.allocBlockRev();
        page_ops.edgeBlockAt(&graph.graph, b, .rev).sources[0] = source.index;
        page_ops.edgeBlockAt(&graph.graph, b, .rev).mask = constants.denseMask(1);
        const dn = try graph.nodeAt(dest_b);
        helpers.clearPublishedSides(dn);
        helpers.publishedRevSide(dn).first_block = b;
        helpers.publishedRevSide(dn).block_count = 1;
        helpers.setPublishedRevDegree(dn, 1);
    }

    graph.graph.edge_count.store(2, .release);

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));

    // dest_b's reverse must NOT have been cleaned (removeNode aborted before publish).
    try testing.expectEqual(@as(u22, 1), helpers.publishedDegrees(try graph.nodeAt(dest_b)).rev);
    try testing.expectEqual(@as(u22, 1), helpers.publishedDegrees(try graph.nodeAt(dest_a)).rev);
}

test "regression: removeNode returns CorruptGraph when grouped reverse chain is shorter than declared group count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const src_a = try graph.addNode();
    const src_b = try graph.addNode();

    // Forward edges from sources to target
    {
        const b = try graph.allocBlockFwd();
        page_ops.edgeBlockAt(&graph.graph, b, .fwd).edges[0] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
        page_ops.edgeBlockAt(&graph.graph, b, .fwd).mask = constants.denseMask(1);
        const sn = try graph.nodeAt(src_a);
        helpers.clearPublishedSides(sn);
        helpers.publishedFwdSide(sn).first_block = b;
        helpers.publishedFwdSide(sn).block_count = 1;
        helpers.setPublishedFwdDegree(sn, 1);
    }
    {
        const b = try graph.allocBlockFwd();
        page_ops.edgeBlockAt(&graph.graph, b, .fwd).edges[0] = .{ .destination = target.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
        page_ops.edgeBlockAt(&graph.graph, b, .fwd).mask = constants.denseMask(1);
        const sn = try graph.nodeAt(src_b);
        helpers.clearPublishedSides(sn);
        helpers.publishedFwdSide(sn).first_block = b;
        helpers.publishedFwdSide(sn).block_count = 1;
        helpers.setPublishedFwdDegree(sn, 1);
    }

    // Grouped reverse on target with broken chain
    const r0 = try graph.allocBlockRev();
    const r1 = try graph.allocBlockRev();
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).sources[0] = src_a.index;
    page_ops.edgeBlockAt(&graph.graph, r0, .rev).mask = constants.denseMask(1);
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).sources[0] = src_b.index;
    page_ops.edgeBlockAt(&graph.graph, r1, .rev).mask = constants.denseMask(1);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = r0, .count = 1, .next = g1 };
    page_ops.groupAt(&graph.graph, g1).* = .{ .start = r1, .count = 1, .next = constants.END_OF_CHAIN };

    const target_node = try graph.nodeAt(target);
    helpers.clearPublishedSides(target_node);
    helpers.publishedRevSide(target_node).block_count = 2;
    helpers.publishedRevSide(target_node).group_count = 2;
    helpers.publishedRevSide(target_node).first_group = g0;
    helpers.setPublishedRevDegree(target_node, 2);

    // Truncate reverse chain.
    page_ops.groupAt(&graph.graph, g0).next = constants.END_OF_CHAIN;

    graph.graph.edge_count.store(2, .release);

    // Broken reverse chain: src_b is a live predecessor whose reverse entry
    // cannot be reached. removeNode must detect the bijection gap.
    try testing.expectError(error.CorruptGraph, graph.removeNode(target));

    // src_a's forward degree should be untouched.
    try testing.expectEqual(@as(u22, 1), helpers.publishedDegrees(try graph.nodeAt(src_a)).fwd);
    try testing.expectEqual(@as(u22, 1), helpers.publishedDegrees(try graph.nodeAt(src_b)).fwd);
}

test "regression: validate and debugValidate agree on grouped chain shorter than declared group count" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    const b0 = try graph.allocBlockFwd();
    const g0 = try graph.allocGroup();
    page_ops.edgeBlockAt(&graph.graph, b0, .fwd).mask = constants.denseMask(1);
    page_ops.groupAt(&graph.graph, g0).* = .{ .start = b0, .count = 1, .next = constants.END_OF_CHAIN };

    const node_buffer = try graph.nodeAt(node);
    helpers.clearPublishedSides(node_buffer);
    helpers.publishedFwdSide(node_buffer).block_count = 2;
    helpers.publishedFwdSide(node_buffer).group_count = 2;
    helpers.publishedFwdSide(node_buffer).first_group = g0;
    helpers.setPublishedFwdDegree(node_buffer, 2);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
