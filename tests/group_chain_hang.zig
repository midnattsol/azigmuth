//! Tests that cyclic or corrupt EdgeBlockGroup chains are detected by
//! validate() and do NOT hang mutation/query APIs.

const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const constants = test_internals.constants;
const helpers = @import("helpers.zig");

const testing = std.testing;

fn makeAdjacencyGroupedWithCycle(graph: *graph_mod.Graph, node: graph_mod.NodeId) !void {
    const published_adj = (try graph.nodeAtConst(node)).publishedAdj();
    if (published_adj.block_count_fwd == 0) return error.SkipZigTest;

    const existing_blocks = published_adj.block_count_fwd;
    const existing_groups = published_adj.group_count_fwd;

    const dangling_block = try graph.allocBlockFwd();
    var block_ptr = page_ops.edgeBlockAt(&graph.graph, dangling_block, .fwd);
    block_ptr.mask = 0;

    if (existing_groups == 0) {
        const g0 = try graph.allocGroup();
        const g1 = try graph.allocGroup();
        page_ops.groupAt(&graph.graph, g0).* = .{
            .start = published_adj.first_block_fwd,
            .count = existing_blocks,
            .next = g1,
        };
        page_ops.groupAt(&graph.graph, g1).* = .{
            .start = dangling_block,
            .count = 1,
            .next = g0,
        };
        const buf = try graph.nodeAt(node);
        helpers.publishedFwdSide(buf).group_count = 2;
        helpers.publishedFwdSide(buf).first_group = g0;
        helpers.publishedFwdSide(buf).block_count += 1;
    } else {
        var tail_idx = published_adj.first_group_fwd;
        while (true) {
            const g = page_ops.groupAtConst(&graph.graph, tail_idx);
            if (g.next == constants.END_OF_CHAIN) break;
            tail_idx = g.next;
        }
        const cycle_group = try graph.allocGroup();
        page_ops.groupAt(&graph.graph, cycle_group).* = .{
            .start = dangling_block,
            .count = 1,
            .next = cycle_group,
        };
        page_ops.groupAt(&graph.graph, tail_idx).next = cycle_group;
        const buf = try graph.nodeAt(node);
        helpers.publishedFwdSide(buf).group_count += 1;
        helpers.publishedFwdSide(buf).block_count += 1;
    }
}

test "group chain: validate detects cyclic forward group chain on contiguous adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);
    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "group chain: validate detects cyclic forward group chain on already-grouped adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..65) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }

    const published_adj = (try graph.nodeAtConst(src)).publishedAdj();
    var tail_idx = published_adj.first_group_fwd;
    while (true) {
        const g = page_ops.groupAtConst(&graph.graph, tail_idx);
        if (g.next == constants.END_OF_CHAIN) break;
        tail_idx = g.next;
    }
    const cycle_group = try graph.allocGroup();
    page_ops.groupAt(&graph.graph, cycle_group).* = .{
        .start = 0,
        .count = 1,
        .next = cycle_group,
    };
    page_ops.groupAt(&graph.graph, tail_idx).next = cycle_group;
    const buf = try graph.nodeAt(src);
    helpers.publishedFwdSide(buf).group_count += 1;

    try testing.expectError(error.CorruptGraph, graph.validate());
}

test "group chain: hasEdgeInAdj on cyclic chain with absent target does not hang" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    const absent = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    // absent is not an edge destination — the cyclic scan should terminate
    // via bounded traversal and return false without hanging.
    try testing.expect(!graph.hasEdgeInAdj((try graph.nodeAtConst(src)).publishedAdj(), absent.index));
}

test "group chain: tailBlockIndex on cyclic chain returns null (does not hang)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    const adj = (try graph.nodeAtConst(src)).publishedAdj();
    if (adj.group_count_fwd > 0) {
        const side_adj = (try graph.nodeAtConst(src)).publishedFwd();
        try testing.expect(test_internals.adjacency.tailBlockIndexSide(&graph.graph, &side_adj) == null);
    }
}

test "group chain: neighbors on cyclic chain does not hang" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    var it = try graph.neighbors(src);
    defer it.deinit();
    _ = it.next(); // must return quickly, not hang
}

test "group chain: neighbors on cyclic chain terminates without duplicates" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    var it = try graph.neighbors(src);
    defer it.deinit();

    // Bound to 5 calls so the bug exposes itself without hanging.
    var count: usize = 0;
    for (0..5) |_| {
        if (it.next()) |neighbor| {
            count += 1;
            try testing.expectEqual(dst.index, neighbor.index);
        } else {
            break;
        }
    }
    // Correct: exactly 1 result, then null. Bug: iterator wraps the
    // cycle and returns duplicates forever (count == 5 here).
    try testing.expectEqual(@as(usize, 1), count);
}

test "group chain: repairNode on cyclic forward chain returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try makeAdjacencyGroupedWithCycle(&graph, src);
    {
        const buf = try graph.nodeAt(src);
        helpers.setPublishedFlags(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    }

    try testing.expectError(error.CorruptGraph, graph.repairNode(src));
}

test "group chain: repairBudgeted on cyclic chain returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try makeAdjacencyGroupedWithCycle(&graph, src);
    {
        const buf = try graph.nodeAt(src);
        helpers.setPublishedFlags(buf, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    }
    try graph.graph.repair_fwd.append(graph.graph.allocator, src.index);

    try testing.expectError(error.CorruptGraph, graph.repairBudgeted(1));
}

test "group chain: removeEdge on cyclic grouped forward adjacency returns CorruptGraph" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    _ = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try makeAdjacencyGroupedWithCycle(&graph, src);

    // The edge against 'dst' still structurally exists.  removeEdge
    // finds it (lookup is bounded), but the grouped-chain rebuild
    // (applyRemovalPlanSide → rebuildAdjWithReplaceSide) is unbounded.
    try testing.expectError(error.CorruptGraph, graph.removeEdge(src, dst));
}

test "group chain: validate does not hang on cyclic chain with forward tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    const removed = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    // Insert a tombstone entry pointing to the removed node into src's forward.
    const src_buf = try graph.nodeAt(src);
    const published_fwd = src_buf.publishedFwd();
    if (published_fwd.block_count > 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, published_fwd.first_block, .fwd);
        const live: u7 = @intCast(@popCount(block.mask));
        // Overwrite the first entry to point to the removed node.
        if (live > 0) {
            block.edges[0].destination = removed.index;
        }
    }

    // Mark the target node as removed so the edge becomes a tombstone.
    {
        const removed_buf = try graph.nodeAt(removed);
        var meta = removed_buf.loadPublishedMeta();
        meta.removed = true;
        removed_buf.storePublishedMeta(meta);
    }

    // Set needs_repair_fwd = false to force forwardHasTombstone path.
    {
        var flags = src_buf.loadPublishedMeta().flags();
        flags.needs_repair_fwd = false;
        helpers.setPublishedFlags(src_buf, flags);
    }

    // validate() must not hang — must either return CorruptGraph or succeed.
    _ = graph.validate() catch {};

    // debugValidate must also terminate.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    // Must emit either forward_tombstone_missing_repair_flag or a cyclic chain violation.
    var found = false;
    for (violations) |v| {
        if (v == .forward_tombstone_missing_repair_flag or
            v == .blockgroup_chain_cycle)
        {
            found = true;
        }
    }
    try testing.expect(found);
}

test "group chain: debugValidate terminates on cyclic chain with tombstone" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    const removed = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    try makeAdjacencyGroupedWithCycle(&graph, src);

    const src_buf = try graph.nodeAt(src);
    const published_fwd = src_buf.publishedFwd();
    if (published_fwd.block_count > 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, published_fwd.first_block, .fwd);
        const live: u7 = @intCast(@popCount(block.mask));
        if (live > 0) {
            block.edges[0].destination = removed.index;
        }
    }

    {
        const removed_buf = try graph.nodeAt(removed);
        var meta = removed_buf.loadPublishedMeta();
        meta.removed = true;
        removed_buf.storePublishedMeta(meta);
    }

    {
        var flags = src_buf.loadPublishedMeta().flags();
        flags.needs_repair_fwd = false;
        helpers.setPublishedFlags(src_buf, flags);
    }

    // debugValidate must terminate quickly.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}
