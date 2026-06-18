const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;

const testing = std.testing;

test "segment lifecycle: alloc, retire, reclaim puts segment back on free list" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const segment = try graph.allocSegment();

    // Retire via page_ops directly.
    const epoch = graph.graph.epoch.load(.acquire);
    page_ops.retireSegment(&graph.graph, segment, epoch);

    // Verify the retired head changed (segment was pushed).
    const retired_head = graph.graph.retired_segment_slots_head[0].load(.acquire);
    try testing.expect(retired_head != constants.END_OF_CHAIN);

    // Bump epoch past the retired epoch and reclaim.
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    // Verify segment was reclaimed (moved from retired to free).
    const free_head = graph.graph.free_segment_slots_head[0].load(.acquire);
    try testing.expect(free_head != constants.END_OF_CHAIN);
}

test "segment lifecycle: alloc followed by free puts segment on free list immediately" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const segment = try graph.allocSegment();
    graph.freeSegment(segment);

    const free_head = graph.graph.free_segment_slots_head[0].load(.acquire);
    try testing.expect(free_head != constants.END_OF_CHAIN);
}
