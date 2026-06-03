const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const testing = std.testing;

test "node pages: nodePageCount returns 1 for a graph with up to NODES_PER_PAGE nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..constants.NODES_PER_PAGE) |_| {
        _ = try graph.addNode();
    }
    try testing.expectEqual(@as(usize, 1), graph.nodePageCount());
    try testing.expectEqual(@as(usize, constants.NODES_PER_PAGE), graph.nodeCount());
}

test "node pages: crossing into the second page reports nodePageCount = 2" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..constants.NODES_PER_PAGE + 5) |_| {
        _ = try graph.addNode();
    }
    try testing.expectEqual(@as(usize, 2), graph.nodePageCount());
    try testing.expectEqual(@as(usize, constants.NODES_PER_PAGE + 5), graph.nodeCount());
}

test "node pages: crossing three pages reports nodePageCount = 3" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const total_nodes: usize = constants.NODES_PER_PAGE * 3;
    for (0..total_nodes) |_| {
        _ = try graph.addNode();
    }
    try testing.expectEqual(@as(usize, 3), graph.nodePageCount());
    try testing.expectEqual(@as(usize, total_nodes), graph.nodeCount());
    try graph.validate();
}

test "node pages: a node that lives in the second page still answers neighbors correctly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..constants.NODES_PER_PAGE - 1) |_| {
        _ = try graph.addNode();
    }
    const cross_page_target = try graph.addNode();
    try graph.addEdge(source, cross_page_target, 0, 0);

    var iterator = try graph.neighbors(source);
    const list = try iterator.materialize(testing.allocator);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(cross_page_target.index, list[0].index);

    var incoming = try graph.inNeighbors(cross_page_target);
    const incoming_list = try incoming.materialize(testing.allocator);
    defer testing.allocator.free(incoming_list);
    try testing.expectEqual(@as(usize, 1), incoming_list.len);
    try testing.expectEqual(source.index, incoming_list[0].index);
}

test "node pages: nodePageCount formula is consistent with nodeCount" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const nodes_per_page = constants.NODES_PER_PAGE;
    // Test the formula: pageCount = pageOf(nodeCount - 1) + 1
    for (0..nodes_per_page * 4 + 7) |_| {
        _ = try graph.addNode();
    }
    const count = graph.nodeCount();
    const page_count = graph.nodePageCount();
    const expected = if (count == 0) @as(usize, 1) else @as(usize, (count - 1) / nodes_per_page + 1);
    try testing.expectEqual(expected, page_count);
}
