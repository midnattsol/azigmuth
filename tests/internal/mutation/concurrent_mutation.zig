const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;

const testing = std.testing;

test "concurrent mutation: claimed adjacency returns ConcurrentMutation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const source_claim = &page_ops.nodeHotAt(&graph.graph, source).claim_fwd;
    try testing.expectEqual(@as(u8, 0), source_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) orelse 0);
    defer source_claim.store(0, .release);

    try testing.expectError(error.ConcurrentMutation, graph.addEdge(source, destination, 0, 0));
}
