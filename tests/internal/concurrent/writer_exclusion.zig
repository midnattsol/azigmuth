const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const testing = std.testing;

fn hotFwd(graph: *graph_mod.Graph, node: graph_mod.NodeId) !*std.atomic.Value(u8) {
    return &page_ops.nodeHotAt(&graph.graph, node).fwd_claim;
}

fn hotRev(graph: *graph_mod.Graph, node: graph_mod.NodeId) !*std.atomic.Value(u8) {
    return &page_ops.nodeHotAt(&graph.graph, node).rev_claim;
}

test "concurrent: sanity — two disjoint edge pairs succeed sequentially" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();
    const d = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(c, d, 0, 0);

    try graph.validate();
}

test "concurrent: claim on source forward fails when already claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const dst1 = try graph.addNode();
    const dst2 = try graph.addNode();

    const claim = try hotFwd(&graph, source);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, dst1, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, dst2, 0, 0));
}

test "concurrent: claim on destination reverse fails when already claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const destination = try graph.addNode();

    const claim = try hotRev(&graph, destination);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src, destination, 0, 0));
}

test "concurrent: self-edge claims both adjacencies of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);

    try testing.expectEqual(@as(u8, 0), (try hotFwd(&graph, node)).load(.acquire));
    try testing.expectEqual(@as(u8, 0), (try hotRev(&graph, node)).load(.acquire));

    try graph.validate();
}

test "concurrent: two writers to same destination reverse both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src1 = try graph.addNode();
    const src2 = try graph.addNode();
    const destination = try graph.addNode();

    const claim = try hotRev(&graph, destination);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src1, destination, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src2, destination, 0, 0));
}

test "concurrent: claim released after mutation allows next writer" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, destination, 0, 0);

    try testing.expectEqual(@as(u8, 0), (try hotFwd(&graph, source)).load(.acquire));
    try testing.expectEqual(@as(u8, 0), (try hotRev(&graph, source)).load(.acquire));

    try graph.addEdge(source, try graph.addNode(), 0, 0);
    try graph.validate();
}

test "concurrent: removeEdge claim fails when forward claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const claim = try hotFwd(&graph, source);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
}

test "concurrent: removeEdge claim fails when reverse claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const claim = try hotRev(&graph, destination);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
}

test "concurrent: removeNode claims both sides of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const other = try graph.addNode();
    try graph.addEdge(node, other, 0, 0);
    try graph.addEdge(other, node, 0, 0);

    const fwd_claim = try hotFwd(&graph, node);
    const rev_claim = try hotRev(&graph, node);
    try testing.expectEqual(@as(u8, 0), fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        fwd_claim.store(0, .release);
        rev_claim.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.removeNode(node));
}

test "concurrent: repairNode claims both sides of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    for (0..100) |_| {
        const t = try graph.addNode();
        try graph.addEdge(node, t, 0, 0);
    }

    const fwd_claim = try hotFwd(&graph, node);
    const rev_claim = try hotRev(&graph, node);
    try testing.expectEqual(@as(u8, 0), fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        fwd_claim.store(0, .release);
        rev_claim.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.repairNode(node));
}

test "concurrent: two nodes claiming each other's opposite sides both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const a_claim = try hotFwd(&graph, a);
    const b_claim = try hotRev(&graph, b);

    try testing.expectEqual(@as(u8, 0), a_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), b_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        a_claim.store(0, .release);
        b_claim.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(a, b, 0, 0));
}

test "concurrent: active_writers counter increments and decrements correctly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const before = graph.graph.active_writers.load(.acquire);
_ = try graph.addNode();
    const after = graph.graph.active_writers.load(.acquire);
    try testing.expectEqual(before, after);
}

test "concurrent: claim succeeds on unclaimed adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const claim = try hotFwd(&graph, node);

    const result = claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(result == null);
    defer claim.store(0, .release);

    const after_claim = claim.load(.acquire);
    try testing.expectEqual(@as(u8, 1), after_claim);
}

test "concurrent: claim on already-claimed returns existing value" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const claim = try hotFwd(&graph, node);

    const first = claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(first == null);
    defer claim.store(0, .release);

    const second = claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(second != null);
}

test "concurrent: forward claim and reverse claim independent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const fwd_claim = try hotFwd(&graph, node);
    const rev_claim = try hotRev(&graph, node);

    const fwd_result = fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(fwd_result == null);
    defer fwd_claim.store(0, .release);

    const rev_result = rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(rev_result == null);
    defer rev_claim.store(0, .release);

    try testing.expectEqual(@as(u8, 1), fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 1), rev_claim.load(.acquire));
}
