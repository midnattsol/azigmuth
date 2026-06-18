const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const testing = std.testing;

fn forwardClaim(graph: *graph_mod.Graph, node: graph_mod.NodeId) !*std.atomic.Value(u8) {
    return &page_ops.nodeMutationControlAt(&graph.graph, node).claim_fwd;
}

fn reverseClaim(graph: *graph_mod.Graph, node: graph_mod.NodeId) !*std.atomic.Value(u8) {
    return &page_ops.nodeMutationControlAt(&graph.graph, node).claim_rev;
}

test "concurrent: sanity — two disjoint edge pairs succeed sequentially" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source_one = try graph.addNode();
    const destination_one = try graph.addNode();
    const source_two = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source_one, destination_one, 0, 0);
    try graph.addEdge(source_two, destination, 0, 0);

    try graph.validate();
}

test "concurrent: claim on source forward fails when already claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_one = try graph.addNode();
    const destination_two = try graph.addNode();

    const claim = try forwardClaim(&graph, source);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination_one, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination_two, 0, 0));
}

test "concurrent: claim on destination reverse fails when already claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const claim = try reverseClaim(&graph, destination);
    try testing.expectEqual(@as(u8, 0), claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination, 0, 0));
}

test "concurrent: self-edge claims both adjacencies of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);

    try testing.expectEqual(@as(u8, 0), (try forwardClaim(&graph, node)).load(.acquire));
    try testing.expectEqual(@as(u8, 0), (try reverseClaim(&graph, node)).load(.acquire));

    try graph.validate();
}

test "concurrent: two writers to same destination reverse both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src1 = try graph.addNode();
    const src2 = try graph.addNode();
    const destination = try graph.addNode();

    const claim = try reverseClaim(&graph, destination);
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

    try testing.expectEqual(@as(u8, 0), (try forwardClaim(&graph, source)).load(.acquire));
    try testing.expectEqual(@as(u8, 0), (try reverseClaim(&graph, source)).load(.acquire));

    try graph.addEdge(source, try graph.addNode(), 0, 0);
    try graph.validate();
}

test "concurrent: removeEdge claim fails when forward claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const claim = try forwardClaim(&graph, source);
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

    const claim = try reverseClaim(&graph, destination);
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

    const claim_fwd = try forwardClaim(&graph, node);
    const claim_rev = try reverseClaim(&graph, node);
    try testing.expectEqual(@as(u8, 0), claim_fwd.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), claim_rev.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        claim_fwd.store(0, .release);
        claim_rev.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.removeNode(node));
}

test "concurrent: repairNode claims both sides of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    for (0..100) |_| {
        const target = try graph.addNode();
        try graph.addEdge(node, target, 0, 0);
    }

    const claim_fwd = try forwardClaim(&graph, node);
    const claim_rev = try reverseClaim(&graph, node);
    try testing.expectEqual(@as(u8, 0), claim_fwd.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), claim_rev.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        claim_fwd.store(0, .release);
        claim_rev.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.repairNode(node));
}

test "concurrent: two nodes claiming each other's opposite sides both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const source_claim = try forwardClaim(&graph, source);
    const destination_claim = try reverseClaim(&graph, destination);

    try testing.expectEqual(@as(u8, 0), source_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), destination_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        source_claim.store(0, .release);
        destination_claim.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination, 0, 0));
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
    const claim = try forwardClaim(&graph, node);

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
    const claim = try forwardClaim(&graph, node);

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
    const claim_fwd = try forwardClaim(&graph, node);
    const claim_rev = try reverseClaim(&graph, node);

    const fwd_result = claim_fwd.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(fwd_result == null);
    defer claim_fwd.store(0, .release);

    const rev_result = claim_rev.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(rev_result == null);
    defer claim_rev.store(0, .release);

    try testing.expectEqual(@as(u8, 1), claim_fwd.load(.acquire));
    try testing.expectEqual(@as(u8, 1), claim_rev.load(.acquire));
}
