//! White-box coverage for the grouped-run validate/sum helpers and the
//! layout-debt group walker. Like the alive-count paths, these are lazily
//! compiled and only reachable from debug validation, so they need direct
//! instantiation to survive layout refactors.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const constants = graph_mod.constants_mod;
const shape = graph_mod.validate_shape_mod;
const sums = graph_mod.validate_sums_mod;
const layout_debt = graph_mod.layout_debt_mod;
const publish = @import("publish");

const testing = std.testing;

const GroupedFixture = struct {
    node: graph_mod.NodeId,
    first_group: u32,
    adj: types.NodeAdj,
};

/// Publishes a node whose forward side is two grouped runs: one full block
/// (64 alive) and one tail block (4 alive), 68 edges total.
fn setUpGroupedForward(graph: *graph_mod.Graph) !GroupedFixture {
    // validateBlockShapeFast rejects keys >= publishedNodeCount, so every
    // destination written below must be a published node index.
    var nodes: [70]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const blk0 = try graph.allocBlockFwd();
    const b0 = page_ops.edgeBlockAt(&graph.graph, blk0, .fwd);
    for (0..64) |slot| {
        b0.destinations[slot] = nodes[slot].index;
        b0.relations[slot] = 0;
        b0.flags[slot] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk0, .fwd, 64);

    const blk1 = try graph.allocBlockFwd();
    const b1 = page_ops.edgeBlockAt(&graph.graph, blk1, .fwd);
    for (0..4) |slot| {
        b1.destinations[slot] = nodes[64 + slot].index;
        b1.relations[slot] = 0;
        b1.flags[slot] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk1, .fwd, 4);

    const g0 = try graph.allocGroup();
    const g1 = try graph.allocGroup();
    page_ops.edgeBlockGroupAt(&graph.graph, g0).* = .{ .start = blk0, .count = 1 };
    page_ops.edgeBlockGroupAt(&graph.graph, g1).* = .{ .start = blk1, .count = 1 };

    const node = nodes[69];
    const ref = try graph.nodeAt(node);
    publish.clearPublishedSides(ref);
    publish.publishedFwdSide(ref).first_block = blk0;
    publish.publishedFwdSide(ref).block_count = 2;
    publish.publishedFwdSide(ref).group_count = 2;
    publish.publishedFwdSide(ref).first_group = g0;
    publish.setPublishedFwdDegree(ref, 68);
    try publish.syncToPublished(graph, node.index);

    return .{ .node = node, .first_group = g0, .adj = ref.publishedAdj() };
}

test "grouped validate paths: sums over grouped forward runs" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpGroupedForward(&graph);

    try testing.expectEqual(@as(u64, 68), sums.sumGroupedRuns(&graph.graph, fixture.first_group, 2, .fwd));
    try testing.expectEqual(@as(u64, 68), sums.sumAdjacency(&graph.graph, fixture.adj, .fwd));
    try testing.expectEqual(@as(u64, 0), sums.sumAdjacency(&graph.graph, fixture.adj, .rev));

    // A group span that runs past the allocated group pool sums to zero
    // instead of touching out-of-range groups.
    try testing.expectEqual(@as(u64, 0), sums.sumGroupedRuns(&graph.graph, fixture.first_group, 200, .fwd));
}

test "grouped validate paths: dense and fast shape checks over grouped forward runs" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpGroupedForward(&graph);

    try shape.validateDenseInGroupedRuns(&graph.graph, fixture.first_group, 2, .fwd);
    try shape.validateDenseMasks(&graph.graph, fixture.adj, .fwd);
    try shape.validateDenseMasks(&graph.graph, fixture.adj, .rev);
    try testing.expectEqual(@as(u64, 68), try shape.validateGroupedRunsFast(&graph.graph, fixture.first_group, 2, .fwd));

    // Group spans that exceed the allocated pool are corruption.
    try testing.expectError(error.CorruptGraph, shape.validateDenseInGroupedRuns(&graph.graph, fixture.first_group, 200, .fwd));
    try testing.expectError(error.CorruptGraph, shape.validateGroupedRunsFast(&graph.graph, fixture.first_group, 200, .fwd));
}

test "grouped validate paths: validateGroupedRunsFast rejects empty groups" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpGroupedForward(&graph);

    // Empty a group in place: the fast walk must flag it.
    const second_group = fixture.first_group + 1;
    const saved = page_ops.edgeBlockGroupAt(&graph.graph, second_group).*;
    page_ops.edgeBlockGroupAt(&graph.graph, second_group).count = 0;
    try testing.expectError(error.CorruptGraph, shape.validateGroupedRunsFast(&graph.graph, fixture.first_group, 2, .fwd));
    page_ops.edgeBlockGroupAt(&graph.graph, second_group).* = saved;
}

const GroupWalk = struct {
    groups_seen: usize = 0,
    blocks_seen: u32 = 0,
    last_flags_seen: usize = 0,
};

test "grouped validate paths: forEachGroupInSide walks every group and flags the tail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpGroupedForward(&graph);

    const side_view = types.SideAdj{
        .first_block = page_ops.edgeBlockGroupAtConst(&graph.graph, fixture.first_group).start,
        .block_count = 2,
        .group_count = 2,
        .first_group = fixture.first_group,
    };

    var walk = GroupWalk{};
    try layout_debt.forEachGroupInSide(&graph.graph, side_view, .fwd, &walk, struct {
        fn cb(_: anytype, ctx: *GroupWalk, _: u32, group: types.EdgeBlockGroup, is_last: bool) !void {
            ctx.groups_seen += 1;
            ctx.blocks_seen += group.count;
            if (is_last) ctx.last_flags_seen += 1;
        }
    }.cb);

    try testing.expectEqual(@as(usize, 2), walk.groups_seen);
    try testing.expectEqual(@as(u32, 2), walk.blocks_seen);
    try testing.expectEqual(@as(usize, 1), walk.last_flags_seen);

    // Empty side: the walker is a no-op, not an error.
    const empty = types.SideAdj{ .first_block = 0, .block_count = 0, .group_count = 0, .first_group = 0 };
    var empty_walk = GroupWalk{};
    try layout_debt.forEachGroupInSide(&graph.graph, empty, .fwd, &empty_walk, struct {
        fn cb(_: anytype, ctx: *GroupWalk, _: u32, _: types.EdgeBlockGroup, _: bool) !void {
            ctx.groups_seen += 1;
        }
    }.cb);
    try testing.expectEqual(@as(usize, 0), empty_walk.groups_seen);
}
