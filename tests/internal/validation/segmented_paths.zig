//! White-box coverage for the edge-block segment validate/sum helpers and the
//! layout-debt segment walker. Like the alive-count paths, these are lazily
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

const SegmentedFixture = struct {
    node: graph_mod.NodeId,
    first_segment: u32,
    adj: types.NodeAdj,
};

/// Publishes a node whose forward side is two segmented segments: one full block
/// (64 alive) and one tail block (4 alive), 68 edges total.
fn setUpSegmentedForward(graph: *graph_mod.Graph) !SegmentedFixture {
    // validateBlockShapeFast rejects keys >= publishedNodeCount, so every
    // destination written below must be a published node index.
    var nodes: [70]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

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

    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = blk0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{ .start = blk1, .count = 1 };

    const node = nodes[69];
    const ref = try graph.nodeAt(node);
    publish.clearPublishedSides(ref);
    publish.publishedFwdSide(ref).first_block = blk0;
    publish.publishedFwdSide(ref).block_count = 2;
    publish.publishedFwdSide(ref).segment_count = 2;
    publish.publishedFwdSide(ref).first_segment = g0;
    publish.setPublishedFwdDegree(ref, 68);
    try publish.syncToPublished(graph, node.index);

    return .{ .node = node, .first_segment = g0, .adj = ref.publishedAdj() };
}

test "segmented validate paths: sums over segmented forward segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpSegmentedForward(&graph);

    try testing.expectEqual(@as(u64, 68), sums.sumSegments(&graph.graph, fixture.first_segment, 2, .fwd));
    try testing.expectEqual(@as(u64, 68), sums.sumAdjacency(&graph.graph, fixture.adj, .fwd));
    try testing.expectEqual(@as(u64, 0), sums.sumAdjacency(&graph.graph, fixture.adj, .rev));

    // A segment slot_entry that segments past the allocated segment pool sums to zero
    // instead of touching out-of-range segments.
    try testing.expectEqual(@as(u64, 0), sums.sumSegments(&graph.graph, fixture.first_segment, 200, .fwd));
}

test "segmented validate paths: dense and fast shape checks over segmented forward segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpSegmentedForward(&graph);

    try shape.validateDenseInSegments(&graph.graph, fixture.first_segment, 2, .fwd);
    try shape.validateDenseMasks(&graph.graph, fixture.adj, .fwd);
    try shape.validateDenseMasks(&graph.graph, fixture.adj, .rev);
    try testing.expectEqual(@as(u64, 68), try shape.validateSegmentsFast(&graph.graph, fixture.first_segment, 2, .fwd));

    // Segment segment_descriptors that exceed the allocated pool are corruption.
    try testing.expectError(error.CorruptGraph, shape.validateDenseInSegments(&graph.graph, fixture.first_segment, 200, .fwd));
    try testing.expectError(error.CorruptGraph, shape.validateSegmentsFast(&graph.graph, fixture.first_segment, 200, .fwd));
}

test "segmented validate paths: validateSegmentsFast rejects empty segments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpSegmentedForward(&graph);

    // Empty a segment in place: the fast walk must flag it.
    const second_segment = fixture.first_segment + 1;
    const saved = page_ops.edgeBlockSegmentAt(&graph.graph, second_segment).*;
    page_ops.edgeBlockSegmentAt(&graph.graph, second_segment).count = 0;
    try testing.expectError(error.CorruptGraph, shape.validateSegmentsFast(&graph.graph, fixture.first_segment, 2, .fwd));
    page_ops.edgeBlockSegmentAt(&graph.graph, second_segment).* = saved;
}

const SegmentWalk = struct {
    segments_seen: usize = 0,
    blocks_seen: u32 = 0,
    last_flags_seen: usize = 0,
};

test "segmented validate paths: forEachSegmentInSide walks every segment and flags the tail" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpSegmentedForward(&graph);

    const side_view = types.SideAdj{
        .first_block = page_ops.edgeBlockSegmentAtConst(&graph.graph, fixture.first_segment).start,
        .block_count = 2,
        .segment_count = 2,
        .first_segment = fixture.first_segment,
    };

    var walk = SegmentWalk{};
    try layout_debt.forEachSegmentInSide(&graph.graph, side_view, .fwd, &walk, struct {
        fn cb(_: anytype, ctx: *SegmentWalk, _: u32, segment: types.EdgeBlockSegment, is_last: bool) !void {
            ctx.segments_seen += 1;
            ctx.blocks_seen += segment.count;
            if (is_last) ctx.last_flags_seen += 1;
        }
    }.cb);

    try testing.expectEqual(@as(usize, 2), walk.segments_seen);
    try testing.expectEqual(@as(u32, 2), walk.blocks_seen);
    try testing.expectEqual(@as(usize, 1), walk.last_flags_seen);

    // Empty side: the walker is a no-op, not an error.
    const empty = types.SideAdj{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    var empty_walk = SegmentWalk{};
    try layout_debt.forEachSegmentInSide(&graph.graph, empty, .fwd, &empty_walk, struct {
        fn cb(_: anytype, ctx: *SegmentWalk, _: u32, _: types.EdgeBlockSegment, _: bool) !void {
            ctx.segments_seen += 1;
        }
    }.cb);
    try testing.expectEqual(@as(usize, 0), empty_walk.segments_seen);
}
