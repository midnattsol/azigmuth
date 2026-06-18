//! Coverage for adjacency segment helpers (tailSegment, forEachSegment) and the
//! forward destination-match counter, over both contiguous and segmented
//! side layouts.

const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const adjacency = graph_mod.adjacency_mod;
const segments = graph_mod.adjacency_segments_mod;

const testing = std.testing;

const Fixture = struct {
    blk0: u32,
    blk1: u32,
    g0: u32,
    target: u32,
};

/// Two forward blocks (3 + 2 alive) plus a two-segment chain over them.
/// `target` appears once in each block.
fn setUpBlocks(graph: *graph_mod.Graph) !Fixture {
    var nodes: [8]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();
    const target = nodes[2].index;

    const blk0 = try graph.allocBlockFwd();
    const b0 = page_ops.edgeBlockAt(&graph.graph, blk0, .fwd);
    const dests0 = [_]u32{ nodes[0].index, nodes[1].index, target };
    for (dests0, 0..) |destination, slot| {
        b0.destinations[slot] = destination;
        b0.relations[slot] = 0;
        b0.flags[slot] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk0, .fwd, dests0.len);

    const blk1 = try graph.allocBlockFwd();
    const b1 = page_ops.edgeBlockAt(&graph.graph, blk1, .fwd);
    const dests1 = [_]u32{ target, nodes[5].index };
    for (dests1, 0..) |destination, slot| {
        b1.destinations[slot] = destination;
        b1.relations[slot] = 0;
        b1.flags[slot] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk1, .fwd, dests1.len);

    const g0 = try graph.allocSegment();
    const g1 = try graph.allocSegment();
    page_ops.edgeBlockSegmentAt(&graph.graph, g0).* = .{ .start = blk0, .count = 1 };
    page_ops.edgeBlockSegmentAt(&graph.graph, g1).* = .{ .start = blk1, .count = 1 };

    return .{ .blk0 = blk0, .blk1 = blk1, .g0 = g0, .target = target };
}

test "segments: tailSegment on contiguous, segmented, and empty layouts" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpBlocks(&graph);

    const contiguous = types.SideAdj{ .first_block = fixture.blk0, .block_count = 2, .segment_count = 0, .first_segment = 0 };
    const contiguous_tail = segments.tailSegment(&graph.graph, contiguous) orelse return error.TestExpectedEqual;
    try testing.expectEqual(fixture.blk0, contiguous_tail.start);
    try testing.expectEqual(@as(u32, 2), contiguous_tail.count);

    const segmented = types.SideAdj{ .first_block = fixture.blk0, .block_count = 2, .segment_count = 2, .first_segment = fixture.g0 };
    const segmented_tail = segments.tailSegment(&graph.graph, segmented) orelse return error.TestExpectedEqual;
    try testing.expectEqual(fixture.blk1, segmented_tail.start);
    try testing.expectEqual(@as(u32, 1), segmented_tail.count);

    const empty = types.SideAdj{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    try testing.expectEqual(@as(?segments.SegmentDesc, null), segments.tailSegment(&graph.graph, empty));
}

const RunWalk = struct {
    segments_seen: usize = 0,
    blocks_seen: u32 = 0,
    last_flags_seen: usize = 0,
};

fn walkSegments(graph: *const graph_mod.GraphCore, side_adj: types.SideAdj) !RunWalk {
    var walk = RunWalk{};
    try segments.forEachSegment(graph, side_adj, &walk, struct {
        fn cb(_: anytype, ctx: *RunWalk, segment: segments.SegmentDesc, is_last: bool) !void {
            ctx.segments_seen += 1;
            ctx.blocks_seen += segment.count;
            if (is_last) ctx.last_flags_seen += 1;
        }
    }.cb);
    return walk;
}

test "segments: forEachSegment visits one contiguous segment or every segment" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpBlocks(&graph);

    const contiguous = types.SideAdj{ .first_block = fixture.blk0, .block_count = 2, .segment_count = 0, .first_segment = 0 };
    const contiguous_walk = try walkSegments(&graph.graph, contiguous);
    try testing.expectEqual(@as(usize, 1), contiguous_walk.segments_seen);
    try testing.expectEqual(@as(u32, 2), contiguous_walk.blocks_seen);
    try testing.expectEqual(@as(usize, 1), contiguous_walk.last_flags_seen);

    const segmented = types.SideAdj{ .first_block = fixture.blk0, .block_count = 2, .segment_count = 2, .first_segment = fixture.g0 };
    const segmented_walk = try walkSegments(&graph.graph, segmented);
    try testing.expectEqual(@as(usize, 2), segmented_walk.segments_seen);
    try testing.expectEqual(@as(u32, 2), segmented_walk.blocks_seen);
    try testing.expectEqual(@as(usize, 1), segmented_walk.last_flags_seen);

    const empty = types.SideAdj{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    const empty_walk = try walkSegments(&graph.graph, empty);
    try testing.expectEqual(@as(usize, 0), empty_walk.segments_seen);
}

test "adjacency: countForwardDestinationMatches over contiguous and segmented layouts" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const fixture = try setUpBlocks(&graph);

    // Contiguous slot_entry of both blocks: the target lives once in each.
    try testing.expectEqual(@as(u32, 2), adjacency.countForwardDestinationMatches(&graph.graph, fixture.blk0, 2, 0, 0, fixture.target));
    // Single block.
    try testing.expectEqual(@as(u32, 1), adjacency.countForwardDestinationMatches(&graph.graph, fixture.blk0, 1, 0, 0, fixture.target));
    // Segmented layout.
    try testing.expectEqual(@as(u32, 2), adjacency.countForwardDestinationMatches(&graph.graph, fixture.blk0, 2, 2, fixture.g0, fixture.target));
    // Absent destination.
    try testing.expectEqual(@as(u32, 0), adjacency.countForwardDestinationMatches(&graph.graph, fixture.blk0, 2, 0, 0, 999_999));
    // Invalid layout (slot_entry past the allocated pool) degrades to zero matches.
    try testing.expectEqual(@as(u32, 0), adjacency.countForwardDestinationMatches(&graph.graph, fixture.blk0, 10_000, 0, 0, fixture.target));
}
