const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const page_ops = test_internals.page_ops;
const testing = std.testing;

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

    const node_buffer = try graph.nodeAt(source);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer node_buffer.fwd_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, dst1, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, dst2, 0, 0));
}

test "concurrent: claim on destination reverse fails when already claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const destination = try graph.addNode();

    const node_buffer = try graph.nodeAt(destination);
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer node_buffer.rev_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src, destination, 0, 0));
}

test "concurrent: self-edge claims both adjacencies of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, 0);

    const node_buffer = try graph.nodeAtConst(node);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.load(.acquire));

    try graph.validate();
}

test "concurrent: two writers to same destination reverse both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src1 = try graph.addNode();
    const src2 = try graph.addNode();
    const destination = try graph.addNode();

    const dest_buffer = try graph.nodeAt(destination);
    try testing.expectEqual(@as(u8, 0), dest_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer dest_buffer.rev_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src1, destination, 0, 0));
    try testing.expectError(error.ConcurrentMutation, graph.addEdge(src2, destination, 0, 0));
}

test "concurrent: claim released after mutation allows next writer" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, destination, 0, 0);

    const node_buffer = try graph.nodeAtConst(source);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.load(.acquire));

    try graph.addEdge(source, try graph.addNode(), 0, 0);
    try graph.validate();
}

test "concurrent: removeEdge claim fails when forward claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const node_buffer = try graph.nodeAt(source);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer node_buffer.fwd_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
}

test "concurrent: removeEdge claim fails when reverse claimed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const node_buffer = try graph.nodeAt(destination);
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer node_buffer.rev_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.removeEdge(source, destination));
}

test "concurrent: removeNode claims both sides of same node" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const other = try graph.addNode();
    try graph.addEdge(node, other, 0, 0);
    try graph.addEdge(other, node, 0, 0);

    const node_buffer = try graph.nodeAt(node);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        node_buffer.fwd_claim.store(0, .release);
        node_buffer.rev_claim.store(0, .release);
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

    const node_buffer = try graph.nodeAt(node);
    try testing.expectEqual(@as(u8, 0), node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), node_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        node_buffer.fwd_claim.store(0, .release);
        node_buffer.rev_claim.store(0, .release);
    }

    try testing.expectError(error.ConcurrentMutation, graph.repairNode(node));
}

test "concurrent: two nodes claiming each other's opposite sides both fail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    const a_buffer = try graph.nodeAt(a);
    const b_buffer = try graph.nodeAt(b);

    try testing.expectEqual(@as(u8, 0), a_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    try testing.expectEqual(@as(u8, 0), b_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer {
        a_buffer.fwd_claim.store(0, .release);
        b_buffer.rev_claim.store(0, .release);
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
    const node_buffer = try graph.nodeAt(node);

    const result = node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(result == null);
    defer node_buffer.fwd_claim.store(0, .release);

    const after_claim = node_buffer.fwd_claim.load(.acquire);
    try testing.expectEqual(@as(u8, 1), after_claim);
}

test "concurrent: claim on already-claimed returns existing value" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    const first = node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(first == null);
    defer node_buffer.fwd_claim.store(0, .release);

    const second = node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(second != null);
}

test "concurrent: forward claim and reverse claim independent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    const fwd_result = node_buffer.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(fwd_result == null);
    defer node_buffer.fwd_claim.store(0, .release);

    const rev_result = node_buffer.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire);
    try testing.expect(rev_result == null);
    defer node_buffer.rev_claim.store(0, .release);

    try testing.expectEqual(@as(u8, 1), node_buffer.fwd_claim.load(.acquire));
    try testing.expectEqual(@as(u8, 1), node_buffer.rev_claim.load(.acquire));
}