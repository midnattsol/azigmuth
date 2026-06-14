//! White-box coverage for the lazily-compiled validate helpers that read
//! per-block live counts. These paths are only reachable through debug
//! validation, so without direct instantiation (both sides) a layout change
//! can silently break them.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const common = graph_mod.validate_common_mod;
const sums = graph_mod.validate_sums_mod;
const shape = graph_mod.validate_shape_mod;
const run_search = graph_mod.validate_run_search_mod;
const publish = @import("publish");

const testing = std.testing;

const SlotCounter = struct { total: usize = 0 };

test "alive-count validator paths: sums, shape, and run search (fwd and rev)" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..8) |i| nodes[i] = try graph.addNode();

    const blk_f = try graph.allocBlockFwd();
    const bf = page_ops.edgeBlockAt(&graph.graph, blk_f, .fwd);
    for (0..4) |i| {
        bf.destinations[i] = nodes[i].index;
        bf.relations[i] = 0;
        bf.flags[i] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk_f, .fwd, 4);

    const blk_r = try graph.allocBlockRev();
    const br = page_ops.edgeBlockAt(&graph.graph, blk_r, .rev);
    for (0..4) |i| br.sources[i] = nodes[i].index;
    page_ops.setBlockAliveCount(&graph.graph, blk_r, .rev, 4);

    try testing.expectEqual(@as(u64, 4), sums.sumBlockAlive(&graph.graph, blk_f, .fwd));
    try testing.expectEqual(@as(u64, 4), sums.sumBlockAlive(&graph.graph, blk_r, .rev));
    try testing.expectEqual(@as(u64, 4), sums.countVisibleEntriesInBlock(&graph.graph, blk_f, .fwd));
    try testing.expectEqual(@as(u64, 4), sums.countVisibleEntriesInBlock(&graph.graph, blk_r, .rev));

    try shape.validateBlockDense(&graph.graph, blk_f, .fwd);
    try shape.validateBlockDense(&graph.graph, blk_r, .rev);

    try testing.expectEqual(@as(?u7, 2), run_search.findSlotInRun(&graph.graph, blk_f, 1, nodes[2].index, types.EdgeBlockFwd, .fwd));
    try testing.expectEqual(@as(?u7, 2), run_search.findSlotInRun(&graph.graph, blk_r, 1, nodes[2].index, types.EdgeBlockRev, .rev));
    try testing.expect(run_search.runContainsTarget(&graph.graph, blk_f, 1, nodes[3].index, .fwd));
    try testing.expect(run_search.runContainsTarget(&graph.graph, blk_r, 1, nodes[3].index, .rev));
    try testing.expect(!run_search.runContainsTarget(&graph.graph, blk_f, 1, 999_999, .fwd));
}

test "alive-count validator paths: tombstones are visible to sums but not counted as visible entries" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..4) |i| nodes[i] = try graph.addNode();

    const blk = try graph.allocBlockFwd();
    const bf = page_ops.edgeBlockAt(&graph.graph, blk, .fwd);
    for (0..4) |i| {
        bf.destinations[i] = nodes[i].index;
        bf.relations[i] = 0;
        bf.flags[i] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk, .fwd, 4);

    _ = try graph.removeNode(nodes[2]);

    try testing.expectEqual(@as(u64, 4), sums.sumBlockAlive(&graph.graph, blk, .fwd));
    try testing.expectEqual(@as(u64, 3), sums.countVisibleEntriesInBlock(&graph.graph, blk, .fwd));
}

test "alive-count validator paths: forEachAliveSlotInAdj walks live slots of published blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..8) |i| nodes[i] = try graph.addNode();

    const blk_f = try graph.allocBlockFwd();
    const bf = page_ops.edgeBlockAt(&graph.graph, blk_f, .fwd);
    for (0..4) |i| {
        bf.destinations[i] = nodes[i].index;
        bf.relations[i] = 0;
        bf.flags[i] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk_f, .fwd, 4);

    const blk_r = try graph.allocBlockRev();
    const br = page_ops.edgeBlockAt(&graph.graph, blk_r, .rev);
    for (0..3) |i| br.sources[i] = nodes[i].index;
    page_ops.setBlockAliveCount(&graph.graph, blk_r, .rev, 3);

    const ref = try graph.nodeAt(nodes[7]);
    publish.publishedFwdSide(ref).first_block = blk_f;
    publish.publishedFwdSide(ref).block_count = 1;
    publish.publishedRevSide(ref).first_block = blk_r;
    publish.publishedRevSide(ref).block_count = 1;
    try publish.syncToPublished(&graph, nodes[7].index);

    const adj = ref.publishedAdj();

    var fwd_counter = SlotCounter{};
    try common.forEachAliveSlotInAdj(&graph.graph, adj, .fwd, &fwd_counter, struct {
        fn cb(_: anytype, ctx: *SlotCounter, _: u32, _: usize) !void {
            ctx.total += 1;
        }
    }.cb);
    try testing.expectEqual(@as(usize, 4), fwd_counter.total);

    var rev_counter = SlotCounter{};
    try common.forEachAliveSlotInAdj(&graph.graph, adj, .rev, &rev_counter, struct {
        fn cb(_: anytype, ctx: *SlotCounter, _: u32, _: usize) !void {
            ctx.total += 1;
        }
    }.cb);
    try testing.expectEqual(@as(usize, 3), rev_counter.total);
}
