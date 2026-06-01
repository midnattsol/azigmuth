const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;

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
    try testing.expectEqual(@as(usize, 2), graph.graph.node_pages.items.len);
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
    try testing.expectEqual(@as(usize, 2), graph.graph.edge_blocks_fwd.items.len);
    try testing.expectEqual(@as(usize, 2), graph.graph.edge_blocks_rev.items.len);
}

test "page_ops: group allocation crosses page boundary" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var last_group: u32 = 0;
    for (0..constants.EDGE_GROUPS_PER_PAGE + 1) |_| {
        last_group = try graph.allocGroup();
    }

    try testing.expectEqual(constants.EDGE_GROUPS_PER_PAGE, last_group);
    try testing.expectEqual(@as(usize, 2), graph.graph.edge_block_groups.items.len);
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
    try testing.expect(graph.graph.free_blocks_rev.items.len > 0);

    const next_source = try graph.addNode();
    try graph.addEdge(next_source, destination, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
}
