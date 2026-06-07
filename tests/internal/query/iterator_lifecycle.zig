//! Regression tests for iterator safety after deinit().
//!
//! After `NeighborIterator.deinit()` drops the RCU reader guard, calling
//! `next()` or `snapshotDegree()` again must not access retired/reclaimed
//! block memory.

const std = @import("std");
const graph_mod = @import("graph_mod");
const rcu = graph_mod.repair_mod;

const testing = std.testing;

test "iterator lifecycle: next() after deinit() returns null and is safe" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    var it = try graph.neighbors(src);
    try testing.expect(it.next() != null); // consume the live neighbor
    it.deinit();

    // After deinit the RCU reader guard is dropped; another next() must not
    // traverse block memory from which blocks may have been reclaimed.
    try testing.expect(it.next() == null);
}

test "iterator lifecycle: snapshotDegree() after deinit() returns 0 and is safe" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    var it = try graph.neighbors(src);
    try testing.expectEqual(@as(usize, 1), graph_mod.snapshotDegree(&it));
    it.deinit();

    // snapshotDegree() must not access blocks after the reader guard is gone.
    try testing.expectEqual(@as(usize, 0), graph_mod.snapshotDegree(&it));
}

test "iterator lifecycle: stale copied iterator becomes inert after owner deinit()" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    var it = try graph.neighbors(source);
    var copied = it;

    try testing.expectEqual(@as(usize, 1), graph_mod.snapshotDegree(&copied));
    it.deinit();

    // Copying and using multiple iterator values is unsupported by contract,
    // but stale copies should still become inert instead of touching reclaimed
    // graph storage after the owner releases the reader token.
    try testing.expectEqual(@as(usize, 0), graph_mod.snapshotDegree(&copied));
    try testing.expect(copied.next() == null);
}

test "iterator lifecycle: double deinit() is harmless" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    var it = try graph.neighbors(src);
    it.deinit();
    it.deinit(); // must not double-release the reader slot
}

test "iterator lifecycle: next() and snapshotDegree() stay safe after iterator is consumed and deinited" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [5]graph_mod.NodeId = undefined;
    for (0..5) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    var it = try graph.neighbors(src);
    // Consume all neighbors.
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expect(it.next() == null); // exhausted
    it.deinit();

    // After deinit, everything should be safe no-ops.
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 0), graph_mod.snapshotDegree(&it));
    it.deinit(); // double deinit still safe
}
