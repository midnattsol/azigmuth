//! Coverage for the reader-token retain/release pair. These exist for
//! holders that need to pin a token they did not create (e.g. handing a
//! session token to a helper); nothing in-tree calls them yet, so they are
//! exercised directly.

const std = @import("std");
const graph_mod = @import("graph_mod");
const rcu = graph_mod.rcu_mod;

const testing = std.testing;

test "rcu: retain/release keeps a live token alive" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = try rcu.readerEnter(&graph.graph);

    try testing.expect(rcu.tryRetainReaderToken(&graph.graph, token));
    // Dropping the retained reference leaves the original reference alive.
    try testing.expect(rcu.releaseRetainedReaderToken(&graph.graph, token) == .alive);

    // The cycle is repeatable while the token stays open.
    try testing.expect(rcu.tryRetainReaderToken(&graph.graph, token));
    try testing.expect(rcu.releaseRetainedReaderToken(&graph.graph, token) == .alive);

    rcu.readerExit(&graph.graph, token);
}

test "rcu: retain fails once the token has exited" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = try rcu.readerEnter(&graph.graph);
    rcu.readerExit(&graph.graph, token);

    try testing.expect(!rcu.tryRetainReaderToken(&graph.graph, token));
}

test "rcu: retain fails on a stale token after the slot is recycled" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const stale = try rcu.readerEnter(&graph.graph);
    rcu.readerExit(&graph.graph, stale);

    // A new token may land in the same liveness slot with a fresh id; the
    // stale token must not be able to pin it.
    const fresh = try rcu.readerEnter(&graph.graph);
    defer rcu.readerExit(&graph.graph, fresh);

    try testing.expect(!rcu.tryRetainReaderToken(&graph.graph, stale));
}
