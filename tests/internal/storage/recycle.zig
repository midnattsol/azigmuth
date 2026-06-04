const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;

const testing = std.testing;

test "group lifecycle: alloc, retire, reclaim puts group back on free list" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const group = try graph.allocGroup();

    // Retire via page_ops directly.
    const epoch = graph.graph.epoch.load(.acquire);
    page_ops.retireGroup(&graph.graph, group, epoch);

    // Verify the retired head changed (group was pushed).
    const retired_head = graph.graph.retired_groups_head.load(.acquire);
    try testing.expect(retired_head != constants.END_OF_CHAIN);

    // Bump epoch past the retired epoch and reclaim.
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    // Verify group was reclaimed (moved from retired to free).
    const free_head = graph.graph.free_groups_head.load(.acquire);
    try testing.expect(free_head != constants.END_OF_CHAIN);
}

test "group lifecycle: alloc followed by free puts group on free list immediately" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const group = try graph.allocGroup();
    graph.freeGroup(group);

    const free_head = graph.graph.free_groups_head.load(.acquire);
    try testing.expect(free_head != constants.END_OF_CHAIN);
}
