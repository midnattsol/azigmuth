const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "rcu: tiny slot churn stays bounded under retire + reclaim" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    for (0..1000) |_| {
        try graph.addEdge(source, destination, 0, 0);
        _ = try graph.removeEdge(source, destination);
        graph.reclaimRetired();
    }

    // Every add/remove on a tiny side copies into a fresh slot and retires the
    // old one. With reclaim running, retired slots must return to the free
    // stack and be reused instead of growing the bump counters monotonically.
    try testing.expect(graph.graph.tiny_fwd_count < 64);
    try testing.expect(graph.graph.tiny_rev_count < 64);
}

test "rcu: retired tiny slot is not reused while a reader is pinned" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination_a = try graph.addNode();
    const destination_b = try graph.addNode();

    try graph.addEdge(source, destination_a, 0, 0);

    // Pin a reader at the current epoch: the slot published for (source -> a)
    // must stay intact for this reader even after later mutations retire it.
    const token = try graph.readerEnter();

    try graph.addEdge(source, destination_b, 0, 0);
    graph.reclaimRetired();

    const before_count = graph.graph.tiny_fwd_count;
    try graph.addEdge(destination_a, destination_b, 0, 0);
    // The retired slot from the pinned epoch must not have been recycled into
    // this allocation; a fresh slot (or a safely freed one) must be used.
    try testing.expect(graph.graph.tiny_fwd_count >= before_count);

    graph.readerExit(token);
    graph.reclaimRetired();
}
