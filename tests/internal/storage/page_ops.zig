const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;

const testing = std.testing;

test "page_ops: index helpers round-trip page and slot" {
    const entries_per_page: u32 = 256;

    try testing.expectEqual(@as(u32, 0), page_ops.pageOf(0, entries_per_page));
    try testing.expectEqual(@as(u32, 0), page_ops.slotOf(0, entries_per_page));
    try testing.expectEqual(@as(u32, 0), page_ops.pageOf(255, entries_per_page));
    try testing.expectEqual(@as(u32, 255), page_ops.slotOf(255, entries_per_page));
    try testing.expectEqual(@as(u32, 1), page_ops.pageOf(256, entries_per_page));
    try testing.expectEqual(@as(u32, 0), page_ops.slotOf(256, entries_per_page));
    try testing.expectEqual(@as(u32, 513), page_ops.makeIndex(2, 1, entries_per_page));
}

test "page_ops: addNode crosses node page boundary" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var last_node = graph_mod.NodeId{ .index = 0 };
    for (0..constants.NODES_PER_PAGE + 1) |_| {
        last_node = try graph.addNode();
    }

    try testing.expectEqual(@as(u32, constants.NODES_PER_PAGE), last_node.index);
    try testing.expectEqual(@as(usize, 2), graph.nodePageCount());
    try testing.expect(graph.hasNode(.{ .index = constants.NODES_PER_PAGE - 1 }));
    try testing.expect(graph.hasNode(.{ .index = constants.NODES_PER_PAGE }));
}

test "page_ops: forward and reverse block allocation crosses page boundary" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var last_forward_block: u32 = 0;
    var last_reverse_block: u32 = 0;
    for (0..constants.EDGE_BLOCKS_PER_PAGE + 1) |_| {
        last_forward_block = try graph.allocBlockFwd();
        last_reverse_block = try graph.allocBlockRev();
    }

    try testing.expectEqual(constants.EDGE_BLOCKS_PER_PAGE, last_forward_block);
    try testing.expectEqual(constants.EDGE_BLOCKS_PER_PAGE, last_reverse_block);
}

test "page_ops: segment allocation crosses page boundary" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var last_segment: u32 = 0;
    for (0..constants.EDGE_SEGMENTS_PER_PAGE + 1) |_| {
        last_segment = try graph.allocSegment();
    }

    try testing.expectEqual(constants.EDGE_SEGMENTS_PER_PAGE, last_segment);
}

test "page_ops: reused reverse block starts empty" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try testing.expect(try graph.removeEdge(source, destination));

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    const next_source = try graph.addNode();
    try graph.addEdge(next_source, destination, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
}
