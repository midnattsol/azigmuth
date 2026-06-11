//! Direct coverage for storage-level accessors that have no other callers
//! yet (tiny slot editing, node bitmaps, radix capacity, published-degree
//! pointers, dynamic slot reads). Keeping them instantiated here means a
//! layout change cannot silently break them.

const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const tiny = graph_mod.tiny_mod;
const node_bitmap = graph_mod.node_bitmap_mod;
const node_access = graph_mod.node_access_mod;
const node_published = graph_mod.node_published_mod;
const side_ops = graph_mod.side_ops_mod;

const testing = std.testing;

const no_flags: types.EdgeFlags = @bitCast(@as(u16, 0));

test "tiny: fwdCap depends on multigraph mode" {
    try testing.expectEqual(@as(u16, 8), tiny.fwdCap(false));
    try testing.expectEqual(@as(u16, 4), tiny.fwdCap(true));
}

test "tiny: removeFwd shifts the tail down and clears the freed entry" {
    var slot = tiny.TinyFwdSlot{};
    var count: u16 = 0;
    count = try tiny.insertFwd(&slot, count, 10, 1, no_flags, 1, false);
    count = try tiny.insertFwd(&slot, count, 20, 2, no_flags, 2, false);
    count = try tiny.insertFwd(&slot, count, 30, 3, no_flags, 3, false);

    // Miss leaves the slot untouched.
    try testing.expectEqual(@as(?u16, null), tiny.removeFwd(&slot, count, 99, null, false));

    count = tiny.removeFwd(&slot, count, 20, null, false) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 2), count);
    try testing.expectEqual(@as(u32, 10), slot.entries[0].destination);
    try testing.expectEqual(@as(u32, 30), slot.entries[1].destination);
    try testing.expectEqual(@as(u16, 3), slot.entries[1].relation);
    try testing.expectEqual(@as(u32, 0), slot.entries[2].destination);
}

test "tiny: removeFwd in multigraph mode matches on edge id" {
    var slot = tiny.TinyFwdSlot{};
    var count: u16 = 0;
    count = try tiny.insertFwd(&slot, count, 10, 0, no_flags, 7, true);
    count = try tiny.insertFwd(&slot, count, 10, 0, no_flags, 9, true);

    // Wrong edge id is a miss; the right one removes only that parallel edge.
    try testing.expectEqual(@as(?u16, null), tiny.removeFwd(&slot, count, 10, 5, true));
    count = tiny.removeFwd(&slot, count, 10, 7, true) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqual(@as(u32, 9), slot.entries[0].edge_id);
}

test "tiny: removeRev shifts sources down" {
    var slot = tiny.TinyRevSlot{};
    var count: u16 = 0;
    count = tiny.insertRev(&slot, count, 5);
    count = tiny.insertRev(&slot, count, 15);
    count = tiny.insertRev(&slot, count, 25);

    try testing.expectEqual(@as(?u16, null), tiny.removeRev(&slot, count, 99));

    count = tiny.removeRev(&slot, count, 5) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 2), count);
    try testing.expectEqual(@as(u32, 15), slot.sources[0]);
    try testing.expectEqual(@as(u32, 25), slot.sources[1]);
}

test "node_bitmap: ensurePageForNode, setBit and clearBit round-trip" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const directory = &graph.graph.repair_queued_fwd_pages;
    const node_index: u32 = 123;

    try node_bitmap.ensurePageForNode(&graph.graph, directory, node_index);
    try testing.expect(!node_bitmap.isSet(directory, node_index));

    try node_bitmap.setBit(&graph.graph, directory, node_index);
    try testing.expect(node_bitmap.isSet(directory, node_index));
    // Neighboring bits stay untouched.
    try testing.expect(!node_bitmap.isSet(directory, node_index - 1));
    try testing.expect(!node_bitmap.isSet(directory, node_index + 1));

    try node_bitmap.clearBit(&graph.graph, directory, node_index);
    try testing.expect(!node_bitmap.isSet(directory, node_index));
}

test "radix directory: maxPages reports the L1*L2 capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const expected: usize = @as(usize, constants.NODE_PAGE_DIR_L1) * constants.NODE_PAGE_DIR_L2;
    try testing.expectEqual(expected, graph.graph.repair_queued_fwd_pages.maxPages());
}

test "published degrees: pointer accessors read the live published slot" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const pub_a = node_access.nodePublishedAt(&graph.graph, a);
    const meta_a = node_access.loadPublishedMetaAtConst(&graph.graph, a);
    try testing.expectEqual(@as(u32, 1), pub_a.publishedFwdDegree(meta_a).*);
    try testing.expectEqual(@as(u32, 0), pub_a.publishedRevDegree(meta_a).*);

    const pub_b = node_access.nodePublishedAt(&graph.graph, b);
    const meta_b = node_access.loadPublishedMetaAtConst(&graph.graph, b);
    try testing.expectEqual(@as(u32, 0), pub_b.publishedFwdDegree(meta_b).*);
    try testing.expectEqual(@as(u32, 1), pub_b.publishedRevDegree(meta_b).*);
}

test "NodeRef: publishedFwd/publishedRev expose the per-side descriptors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const ref_a = try graph.nodeAt(a);
    const fwd_a = ref_a.publishedFwd();
    try testing.expect(node_published.NodePublished.isTiny(&fwd_a));
    try testing.expectEqual(@as(u16, 1), node_published.NodePublished.tinyCount(&fwd_a));

    const ref_b = try graph.nodeAt(b);
    const rev_b = ref_b.publishedRev();
    try testing.expect(node_published.NodePublished.isTiny(&rev_b));
    try testing.expectEqual(@as(u16, 1), node_published.NodePublished.tinyCount(&rev_b));

    const rev_a = ref_a.publishedRev();
    try testing.expectEqual(@as(u32, 0), rev_a.block_count);
}

test "side_ops: readNodeIdAtSlotDynamic reads both sides with a runtime side" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const blk_f = try graph.allocBlockFwd();
    const bf = page_ops.edgeBlockAt(&graph.graph, blk_f, .fwd);
    for (0..3) |slot| {
        bf.destinations[slot] = nodes[slot].index;
        bf.relations[slot] = 0;
        bf.flags[slot] = 0;
    }
    page_ops.setBlockLiveCount(&graph.graph, blk_f, .fwd, 3);

    const blk_r = try graph.allocBlockRev();
    const br = page_ops.edgeBlockAt(&graph.graph, blk_r, .rev);
    for (0..3) |slot| br.sources[slot] = nodes[3 - slot - 1].index;
    page_ops.setBlockLiveCount(&graph.graph, blk_r, .rev, 3);

    const sides = [_]struct { side: graph_mod.adjacency_mod.AdjSide, block: u32, slot: u7, expected: u32 }{
        .{ .side = .fwd, .block = blk_f, .slot = 0, .expected = nodes[0].index },
        .{ .side = .fwd, .block = blk_f, .slot = 2, .expected = nodes[2].index },
        .{ .side = .rev, .block = blk_r, .slot = 0, .expected = nodes[2].index },
        .{ .side = .rev, .block = blk_r, .slot = 2, .expected = nodes[0].index },
    };
    for (sides) |case| {
        try testing.expectEqual(case.expected, side_ops.readNodeIdAtSlotDynamic(&graph.graph, case.block, case.slot, case.side));
    }
}
