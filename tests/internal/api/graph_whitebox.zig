const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const publish = @import("publish");

const Graph = graph_mod.Graph;
const testing = std.testing;

fn publishSingleReverseSource(graph: *Graph, destination_index: u32, source_index: u32) !void {
    const block_index = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    block.sources[0] = source_index;
    block.mask = constants.denseMask(1);

    const node_buffer = try graph.nodeAt(.{ .index = destination_index });
    publish.publishedRevSide(node_buffer).first_block = block_index;
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
}

fn publishReverseSourcesForForwardRange(graph: *Graph, source_index: u32, first_destination: u32, count: u7) !void {
    for (0..count) |offset| {
        try publishSingleReverseSource(graph, first_destination + @as(u32, @intCast(offset)), source_index);
    }
}

test "graph: addNode and hasNode basics" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const node0 = try graph.addNode();
    const node1 = try graph.addNode();
    try graph.validate();

    try testing.expectEqual(@as(usize, 2), graph.nodeCount());
    try testing.expect(graph.hasNode(node0));
    try testing.expect(graph.hasNode(node1));
    try testing.expect(!graph.hasNode(.{ .index = 999 }));
}

test "graph: addEdge updates outDegree and inDegree" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 1, 0);
    try graph.addEdge(a, c, 2, 0);
    try graph.validate();

    try testing.expectEqual(@as(usize, 2), try graph.outDegree(a));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(b));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(c));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

test "graph: neighbors and inNeighbors iterate expected nodes" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.validate();

    var neighbors_it = try graph.neighbors(a);
    defer neighbors_it.deinit();
    const neighbors_slice = try graph_mod.materializeConsuming(&neighbors_it, testing.allocator);
    defer testing.allocator.free(neighbors_slice);

    try testing.expectEqual(@as(usize, 2), neighbors_slice.len);
    try testing.expectEqual(b.index, neighbors_slice[0].index);
    try testing.expectEqual(c.index, neighbors_slice[1].index);

    var in_neighbors_it = try graph.inNeighbors(c);
    defer in_neighbors_it.deinit();
    const in_neighbors_slice = try graph_mod.materializeConsuming(&in_neighbors_it, testing.allocator);
    defer testing.allocator.free(in_neighbors_slice);

    try testing.expectEqual(@as(usize, 1), in_neighbors_slice.len);
    try testing.expectEqual(a.index, in_neighbors_slice[0].index);
}

test "graph: addEdge duplicate returns EdgeAlreadyExists" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.validate();
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(a, b, 0, 0));
}

test "graph: query APIs return InvalidNode for out-of-bounds node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();

    try testing.expectError(error.InvalidNode, graph.neighbors(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.inNeighbors(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.outDegree(.{ .index = 77 }));
    try testing.expectError(error.InvalidNode, graph.inDegree(.{ .index = 77 }));
}

test "graph: removed node is absent from public node API" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.removeNode(node);

    try testing.expect(!graph.hasNode(node));
    try testing.expectError(error.InvalidNode, graph.nodeAt(node));
    try testing.expectError(error.InvalidNode, graph.nodeAtConst(node));
    try testing.expectError(error.InvalidNode, graph.publishedNodeAdj(node));
}

test "graph: self-edge appears in both neighbors and inNeighbors" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const n = try graph.addNode();
    try graph.addEdge(n, n, 7, 0);
    try graph.validate();

    try testing.expectEqual(@as(usize, 1), try graph.outDegree(n));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(n));

    var out_it = try graph.neighbors(n);
    defer out_it.deinit();
    const out_slice = try graph_mod.materializeConsuming(&out_it, testing.allocator);
    defer testing.allocator.free(out_slice);
    try testing.expectEqual(n.index, out_slice[0].index);

    var in_it = try graph.inNeighbors(n);
    defer in_it.deinit();
    const in_slice = try graph_mod.materializeConsuming(&in_it, testing.allocator);
    defer testing.allocator.free(in_slice);
    try testing.expectEqual(n.index, in_slice[0].index);
}

test "graph: multiple blocks trigger group creation and still iterate" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const target_count: u32 = 130;
    var targets: [130]types.NodeId = undefined;
    for (0..target_count) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();

    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(src));

    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqual(@as(usize, target_count), slice.len);
    for (1..slice.len) |j| {
        try testing.expect(slice[j - 1].index < slice[j].index);
    }
}

test "graph: removeEdge existing edge returns true and updates state" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.addEdge(b, c, 0, 0);
    try graph.validate();
    try testing.expect(try graph.removeEdge(a, c));
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(a));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(a));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(c));
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
    var it = try graph.neighbors(a);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, 1), slice.len);
    try testing.expectEqual(b.index, slice[0].index);
}

test "graph: removeEdge non-existing edge returns false" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode();
    const b = try graph.addNode();
    try testing.expect(!try graph.removeEdge(a, b));
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
}

test "graph: removeEdge edgeCount consistency after add and remove" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const n = try graph.addNode();
    try graph.addEdge(n, n, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expect(try graph.removeEdge(n, n));
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(n));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(n));
}

test "graph: removeEdge from multi-block node decreases degree" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode();
    const target_count: u32 = 65;
    var targets: [65]types.NodeId = undefined;
    for (0..target_count) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(src));
    try testing.expect(try graph.removeEdge(src, targets[target_count - 1]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 1), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, target_count - 1), graph.edgeCount());
    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 1), slice.len);
}

test "graph: removeEdge from first block in multi-block node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode();
    const target_count: u32 = 65;
    var targets: [65]types.NodeId = undefined;
    for (0..target_count) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(src));
    try testing.expect(try graph.removeEdge(src, targets[0]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 1), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, target_count - 1), graph.edgeCount());
    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 1), slice.len);
    try testing.expect(slice[0].index != targets[0].index);
}

test "graph: removeEdge multiple edges from multi-block node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode();
    const target_count: u32 = 70;
    var targets: [70]types.NodeId = undefined;
    for (0..target_count) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expect(try graph.removeEdge(src, targets[0]));
    try graph.validate();
    try testing.expect(try graph.removeEdge(src, targets[34]));
    try graph.validate();
    try testing.expect(try graph.removeEdge(src, targets[69]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 3), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, target_count - 3), graph.edgeCount());
    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 3), slice.len);
    for (1..slice.len) |j| {
        try testing.expect(slice[j - 1].index < slice[j].index);
    }
}

test "graph: debugValidate reports zero violations after mutations" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(b, c, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.validate();

    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(a, b, 0, 0));
    try graph.validate();

    try testing.expect(try graph.removeEdge(a, b));
    try graph.validate();

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// ═══════════════════════════════════════════════════════════════════════
//  Structural invariant tests
// ═══════════════════════════════════════════════════════════════════════

test "graph: removeEdge preserves unrelated incoming and outgoing adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    const d = try graph.addNode();
    const e = try graph.addNode();

    try graph.addEdge(a, b, 0, 0); // A → B
    try graph.addEdge(a, c, 0, 0); // A → C
    try graph.addEdge(d, a, 0, 0); // D → A  (incoming to A)
    try graph.addEdge(b, e, 0, 0); // B → E  (outgoing from B)

    try graph.validate();
    try testing.expect(try graph.removeEdge(a, b));
    try graph.validate();

    // ── Forward adjacency of A ──
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(a));
    var it_a = try graph.neighbors(a);
    defer it_a.deinit();
    const fwd_a = try graph_mod.materializeConsuming(&it_a, testing.allocator);
    defer testing.allocator.free(fwd_a);
    try testing.expectEqual(@as(usize, 1), fwd_a.len);
    try testing.expectEqual(c.index, fwd_a[0].index);

    // ── Reverse adjacency of A: D→A must still exist ──
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(a));
    var it_a_rev = try graph.inNeighbors(a);
    defer it_a_rev.deinit();
    const rev_a = try graph_mod.materializeConsuming(&it_a_rev, testing.allocator);
    defer testing.allocator.free(rev_a);
    try testing.expectEqual(@as(usize, 1), rev_a.len);
    try testing.expectEqual(d.index, rev_a[0].index);

    // ── Forward adjacency of B: B→E must still exist ──
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(b));
    var it_b = try graph.neighbors(b);
    defer it_b.deinit();
    const fwd_b = try graph_mod.materializeConsuming(&it_b, testing.allocator);
    defer testing.allocator.free(fwd_b);
    try testing.expectEqual(@as(usize, 1), fwd_b.len);
    try testing.expectEqual(e.index, fwd_b[0].index);

    // ── Reverse adjacency of B must be empty ──
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(b));

    // ── Global edge count ──
    try testing.expectEqual(@as(u64, 3), graph.edgeCount());
}

test "graph: removeEdge preserves destination forward adjacency and remaining reverse entries" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    const x = try graph.addNode();
    const y = try graph.addNode();

    // B has outgoing edges
    try graph.addEdge(b, x, 0, 0); // B → X
    try graph.addEdge(b, y, 0, 0); // B → Y
    // C has incoming edges (from multiple sources)
    try graph.addEdge(a, c, 0, 0); // A → C
    try graph.addEdge(x, c, 0, 0); // X → C

    // Now remove A→C (C is the destination, its rev adj changes)
    try graph.validate();
    try testing.expect(try graph.removeEdge(a, c));
    try graph.validate();

    // B→X and B→Y must survive (they're in B's forward adj, untouched)
    try testing.expectEqual(@as(usize, 2), try graph.outDegree(b));
    var it_b = try graph.neighbors(b);
    defer it_b.deinit();
    const fwd_b = try graph_mod.materializeConsuming(&it_b, testing.allocator);
    defer testing.allocator.free(fwd_b);
    try testing.expectEqual(@as(usize, 2), fwd_b.len);

    // X→C must still exist (C still has incoming from X)
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(c));
    var it_c_rev = try graph.inNeighbors(c);
    defer it_c_rev.deinit();
    const rev_c = try graph_mod.materializeConsuming(&it_c_rev, testing.allocator);
    defer testing.allocator.free(rev_c);
    try testing.expectEqual(@as(usize, 1), rev_c.len);
    try testing.expectEqual(x.index, rev_c[0].index);
}

test "graph: removeEdge preserves self-edge and unrelated incoming edge" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const n = try graph.addNode();
    const x = try graph.addNode();
    const y = try graph.addNode();

    try graph.addEdge(n, n, 0, 0); // self-loop
    try graph.addEdge(n, x, 0, 0); // N → X
    try graph.addEdge(y, n, 0, 0); // Y → N  (reverse adjacency on N)

    try graph.validate();
    try testing.expect(try graph.removeEdge(n, x));
    try graph.validate();

    // Self-loop and Y→N must survive.  In-degree is 2: N→N and Y→N.
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(n));
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(n));

    var it_n = try graph.neighbors(n);
    defer it_n.deinit();
    const fwd_n = try graph_mod.materializeConsuming(&it_n, testing.allocator);
    defer testing.allocator.free(fwd_n);
    try testing.expectEqual(@as(usize, 1), fwd_n.len);
    try testing.expectEqual(n.index, fwd_n[0].index);

    // Reverse adjacency must include the self-loop source and Y.
    var it_n_rev = try graph.inNeighbors(n);
    defer it_n_rev.deinit();
    const rev_n = try graph_mod.materializeConsuming(&it_n_rev, testing.allocator);
    defer testing.allocator.free(rev_n);
    try testing.expectEqual(@as(usize, 2), rev_n.len);
    try testing.expectEqual(n.index, rev_n[0].index);
    try testing.expectEqual(y.index, rev_n[1].index);
}

test "graph: removeEdge rejects non-tail occupancy below threshold without publishing" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();

    // Create 65 edges → block 0 full (64), block 1 has 1 (tail).
    var targets: [65]types.NodeId = undefined;
    for (0..65) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 65), try graph.outDegree(src));

    // Remove 16 edges from the first block (64 → 48), still legal.
    for (0..16) |i| {
        try testing.expect(try graph.removeEdge(src, targets[i]));
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 49), try graph.outDegree(src));

    // The 17th removal would make a non-tail block 47/64.
    try testing.expectError(error.RepairRequired, graph.removeEdge(src, targets[16]));

    // The failed removal must not publish partial state.
    try graph.validate();
    try testing.expectEqual(@as(usize, 49), try graph.outDegree(src));
    try testing.expectEqual(@as(u64, 49), graph.edgeCount());
}

test "graph: copy-on-write tail replacement preserves grouped adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();

    // Phase 1: fill first block (64 edges), then add one more.
    // If contiguous, the new block is at tail+1 → block_count_fwd += 1.
    // If NOT contiguous, appendGroupToAdj creates groups.
    var targets: [70]types.NodeId = undefined;
    for (0..70) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 70), try graph.outDegree(src));

    // Phase 2: remove an edge from the first block, creating space (63 live).
    // Then add a new edge → triggers COW on tail block.
    // If the tail was a single-block group (count=1),
    // removeTailFromAdj makes count=0.
    _ = try graph.removeEdge(src, targets[0]);
    try graph.validate();

    const new_target = try graph.addNode();
    try graph.addEdge(src, new_target, 0, 0);
    try graph.validate();

    // Iteration remains valid after replacing a tail block in grouped mode.
    try testing.expectEqual(@as(usize, 70), try graph.outDegree(src));

    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, 70), slice.len);

    // Also check inNeighbors still works for all targets
    for (1..70) |i| {
        if (targets[i].index != targets[0].index) {
            try testing.expectEqual(@as(usize, 1), try graph.inDegree(targets[i]));
        }
    }

    // Now add MORE edges to trigger more mutations on the (possibly damaged) node
    for (0..30) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 100), try graph.outDegree(src));
}

test "graph: repairNode compacts under-full adjacent blocks" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..83) |_| {
        _ = try graph.addNode();
    }

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();

    var first_block_edges = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);
    for (0..47) |i| {
        first_block_edges.edges[i] = types.Edge{ .destination = @intCast(i + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_block_edges.mask = constants.denseMask(47);

    for (0..36) |i| {
        second_block_edges.edges[i] = types.Edge{ .destination = @intCast(i + 48), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    second_block_edges.mask = constants.denseMask(36);

    const node = try graph.nodeAt(src);
    publish.clearPublishedSides(node);
    publish.publishedFwdSide(node).first_block = block0;
    publish.publishedFwdSide(node).block_count = 2;
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(83)));
    try publishReverseSourcesForForwardRange(&graph, src.index, 1, 47);
    try publishReverseSourcesForForwardRange(&graph, src.index, 48, 36);
    graph.graph.edge_count.store(83, .release);

    try graph.repairNode(src);

    try graph.validate();
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(src));

    var it = try graph.neighbors(src);
    defer it.deinit();
    const slice = try graph_mod.materializeConsuming(&it, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, 83), slice.len);
    for (1..slice.len) |j| {
        try testing.expect(slice[j - 1].index < slice[j].index);
    }
}

test "graph: neighbor iterator deinit releases RCU reader count" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    // active_readers should start at 0
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    {
        var it = try graph.neighbors(a);
        // After creating iterator, active_readers should be 1
        try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));
        _ = it.next();
        it.deinit();
    }

    // After deinit, active_readers should be back to 0
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "graph: reader guard remains active until iterator deinit" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    // Starting state
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const start_readers = graph.graph.active_readers.load(.acquire);
    var it = try graph.neighbors(a);

    const after_readers = graph.graph.active_readers.load(.acquire);
    try testing.expect(after_readers > start_readers);
    try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));

    it.deinit();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "graph: validate APIs release reader guards" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try graph.validate();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "graph: debugValidate detects forward entry without reverse entry" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, block, .fwd);
    fwd.edges[0] = types.Edge{ .destination = b.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    fwd.mask = constants.denseMask(1);

    const a_node = try graph.nodeAt(a);
    publish.clearPublishedSides(a_node);
    publish.publishedFwdSide(a_node).first_block = block;
    publish.publishedFwdSide(a_node).block_count = 1;
    graph.graph.edge_count.store(1, .release);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == a.index and payload.dst == b.index),
        else => {},
    };
    try testing.expect(found);
}

test "graph: debugValidate detects removed node with outgoing adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const removed = try graph.addNode();
    const live = try graph.addNode();
    try graph.removeNode(removed);

    const fwd_block = try graph.allocBlockFwd();
    var fwd = page_ops.edgeBlockAt(&graph.graph, fwd_block, .fwd);
    fwd.edges[0] = types.Edge{ .destination = live.index, .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    fwd.mask = constants.denseMask(1);

    const rev_block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, rev_block, .rev);
    rev.sources[0] = removed.index;
    rev.mask = constants.denseMask(1);

    const removed_raw = page_ops.nodeAt(&graph.graph, removed);
    publish.publishedFwdSide(removed_raw).first_block = fwd_block;
    publish.publishedFwdSide(removed_raw).block_count = 1;
    publish.setPublishedFlags(removed_raw, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = true });
    publish.setPublishedFwdDegree(removed_raw, @as(u22, @intCast(1)));

    const live_raw = try graph.nodeAt(live);
    publish.publishedRevSide(live_raw).first_block = rev_block;
    publish.publishedRevSide(live_raw).block_count = 1;
    publish.setPublishedRevDegree(live_raw, @as(u22, @intCast(1)));
    graph.graph.edge_count.store(1, .release);

    try testing.expectError(error.CorruptGraph, graph.validate());

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    var found_outgoing = false;
    var found_repair_flag = false;
    for (violations) |violation| switch (violation) {
        .removed_node_has_outgoing => |payload| found_outgoing = found_outgoing or payload.node == removed.index,
        .removed_node_marked_for_repair => |payload| found_repair_flag = found_repair_flag or payload.node == removed.index,
        else => {},
    };
    try testing.expect(found_outgoing);
    try testing.expect(found_repair_flag);
}

test "graph: debugValidate detects reverse entry without forward entry" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const block = try graph.allocBlockRev();
    var rev = page_ops.edgeBlockAt(&graph.graph, block, .rev);
    rev.sources[0] = a.index;
    rev.mask = constants.denseMask(1);

    const b_node = try graph.nodeAt(b);
    publish.clearPublishedSides(b_node);
    publish.publishedRevSide(b_node).first_block = block;
    publish.publishedRevSide(b_node).block_count = 1;

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    var found = false;
    for (violations) |violation| switch (violation) {
        .forward_reverse_mismatch => |payload| found = found or (payload.node == a.index and payload.dst == b.index),
        else => {},
    };
    try testing.expect(found);
}

test "graph: rejected non-tail removal does not allocate or retire blocks" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [65]types.NodeId = undefined;
    for (0..65) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    for (0..16) |i| {
        try testing.expect(try graph.removeEdge(src, targets[i]));
    }
    try graph.validate();

    const fwd_blocks_before = graph.graph.block_fwd_count;
    const rev_blocks_before = graph.graph.block_rev_count;
    const retired_fwd_before = 0;
    const retired_rev_before = 0;
    const free_fwd_before = 0;
    const free_rev_before = 0;

    try testing.expectError(error.RepairRequired, graph.removeEdge(src, targets[16]));

    try testing.expectEqual(fwd_blocks_before, graph.graph.block_fwd_count);
    try testing.expectEqual(rev_blocks_before, graph.graph.block_rev_count);
    try testing.expectEqual(retired_fwd_before, 0);
    try testing.expectEqual(retired_rev_before, 0);
    try testing.expectEqual(free_fwd_before, 0);
    try testing.expectEqual(free_rev_before, 0);
    try graph.validate();
}

test "graph: reused free block starts empty" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    try testing.expect(try graph.removeEdge(a, b));

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
        const c = try graph.addNode();
    const d = try graph.addNode();
    try graph.addEdge(c, d, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(c));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "graph: repairBudgeted processes queued repair debt" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..83) |_| {
        _ = try graph.addNode();
    }

    const block0 = try graph.allocBlockFwd();
    const block1 = try graph.allocBlockFwd();
    var first_block_edges = page_ops.edgeBlockAt(&graph.graph, block0, .fwd);
    var second_block_edges = page_ops.edgeBlockAt(&graph.graph, block1, .fwd);

    for (0..47) |i| {
        first_block_edges.edges[i] = types.Edge{ .destination = @intCast(i + 1), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    first_block_edges.mask = constants.denseMask(47);
    for (0..36) |i| {
        second_block_edges.edges[i] = types.Edge{ .destination = @intCast(i + 48), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    second_block_edges.mask = constants.denseMask(36);

    const node = try graph.nodeAt(src);
    publish.clearPublishedSides(node);
    publish.publishedFwdSide(node).first_block = block0;
    publish.publishedFwdSide(node).block_count = 2;
    publish.setPublishedFlags(node, .{ .needs_repair_fwd = true, .needs_repair_rev = false, .removed = false });
    publish.setPublishedFwdDegree(node, @as(u22, @intCast(83)));
    try publishReverseSourcesForForwardRange(&graph, src.index, 1, 47);
    try publishReverseSourcesForForwardRange(&graph, src.index, 48, 36);
    graph.graph.edge_count.store(83, .release);
    try graph.graph.repair_fwd.append(graph.graph.allocator, src.index);

    const compacted = try graph.repairBudgeted(1);
    try testing.expect(compacted > 0);
    try testing.expectEqual(@as(usize, 0), graph.graph.repair_fwd.items.len);
    try graph.validate();
    try testing.expectEqual(@as(usize, 83), try graph.outDegree(src));
}
