//! Sorted-bit preservation: ascending appends keep the published
//! globally-sorted flag (conclusive binary-search misses for dup checks and
//! removals); out-of-order inserts clear it conservatively.

const std = @import("std");
const graph_mod = @import("graph_mod");
const node_access = graph_mod.node_access_mod;

const testing = std.testing;

fn fwdSorted(graph: *graph_mod.Graph, node: graph_mod.NodeId) bool {
    const meta = node_access.loadPublishedMetaAtConst(&graph.graph, node);
    return node_access.nodePublishedAtConst(&graph.graph, node).publishedFwdSortedFromMeta(meta);
}

fn revSorted(graph: *graph_mod.Graph, node: graph_mod.NodeId) bool {
    const meta = node_access.loadPublishedMetaAtConst(&graph.graph, node);
    return node_access.nodePublishedAtConst(&graph.graph, node).publishedRevSortedFromMeta(meta);
}

test "sorted bit: ascending fan-out keeps the forward side globally sorted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    // 200 edges: tiny → promotion → several blocks, all ascending.
    var destinations: [200]graph_mod.NodeId = undefined;
    for (0..destinations.len) |i| destinations[i] = try graph.addNode();
    for (destinations) |destination| {
        try graph.addEdge(source, destination, 0, 0);
        try testing.expect(fwdSorted(&graph, source));
    }

    // Sorted side: duplicate checks and removals stay correct.
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destinations[0], 0, 0));
    try graph.validate();
}

test "sorted bit: out-of-order insert clears the flag and lookups stay correct" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [80]graph_mod.NodeId = undefined;
    for (0..destinations.len) |i| destinations[i] = try graph.addNode();
    const low = try graph.addNode(); // higher index than all of the above

    // Ascending block-mode fan-out, skipping destinations[0] for later.
    for (destinations[1..]) |destination| try graph.addEdge(source, destination, 0, 0);
    try testing.expect(fwdSorted(&graph, source));

    // destinations[0] has the SMALLEST index → breaks global order.
    try graph.addEdge(source, destinations[0], 0, 0);
    try testing.expect(!fwdSorted(&graph, source));

    // Conservative bit: every lookup still works on the unsorted side.
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destinations[0], 0, 0));
    try testing.expect(try graph.removeEdge(source, destinations[0]));
    try graph.addEdge(source, low, 0, 0);
    try testing.expect(try graph.removeEdge(source, low));
    try graph.validate();
}

test "sorted bit: ascending fan-in keeps the reverse side globally sorted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var sources: [100]graph_mod.NodeId = undefined;
    for (0..sources.len) |i| sources[i] = try graph.addNode();
    const hub = try graph.addNode();

    for (sources) |source| try graph.addEdge(source, hub, 0, 0);
    try testing.expect(revSorted(&graph, hub));
    try graph.validate();
}
