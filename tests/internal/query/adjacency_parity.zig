//! Shape inspection parity tests — verified that SideAdj helpers
//! produce consistent results across contiguous and grouped layouts.

const std = @import("std");
const graph_mod = @import("graph_mod");
const adjacency_mod = graph_mod.adjacency_mod;
const publish = @import("publish");

const testing = std.testing;

test "adjacency parity: tailBlockIndexSide returns the correct tail for contiguous layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [3]graph_mod.NodeId = undefined;
    for (0..targets.len) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(src, targets[target_idx], 0, 0);
    }

    const adj = try publish.ensureForwardBlockLayout(&graph, src);
    const fwd: graph_mod.types_mod.SideAdj = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    const tail = adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd);
    try testing.expect(tail != null);
    try testing.expectEqual(fwd.first_block + fwd.block_count - 1, tail.?);
}

test "adjacency parity: tailBlockIndexSide returns the correct tail for grouped layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..70) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(src, destination, 0, 0);
    }

    const adj = try graph.publishedNodeAdj(src);
    const fwd: graph_mod.types_mod.SideAdj = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    if (fwd.group_count > 0) {
        const tail = adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd);
        try testing.expect(tail != null);
    }
}

test "adjacency parity: tailBlockIndexSide returns null for empty layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    const adj = try graph.publishedNodeAdj(.{ .index = 0 });
    const fwd: graph_mod.types_mod.SideAdj = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    try testing.expectEqual(@as(?u32, null), adjacency_mod.tailBlockIndexSide(&graph.graph, &fwd));
}

test "adjacency parity: hasEdgeInAdj vs hasEdgeInSideAdj agree on contiguous layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const destination_one = try graph.addNode();
    const destination_two = try graph.addNode();
    const destination_three = try graph.addNode();
    try graph.addEdge(src, destination_one, 0, 0);
    try graph.addEdge(src, destination_two, 0, 0);
    try graph.addEdge(src, destination_three, 0, 0);

    const adj = try graph.publishedNodeAdj(src);
    const fwd: graph_mod.types_mod.SideAdj = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };

    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, destination_one.index),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, destination_one.index),
    );
    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, destination_two.index),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, destination_two.index),
    );
    try testing.expectEqual(
        adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 9999),
        adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 9999),
    );
}

test "adjacency parity: hasEdgeInAdj vs hasEdgeInSideAdj agree on grouped layout" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..70) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(src, destination, 0, 0);
    }

    const adj = try graph.publishedNodeAdj(src);
    const fwd: graph_mod.types_mod.SideAdj = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };

    if (adj.group_count_fwd > 0) {
        // Check the first, last, and an absent dest.
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 1),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 1),
        );
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 69),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 69),
        );
        try testing.expectEqual(
            adjacency_mod.hasEdgeInAdj(&graph.graph, adj, 9999),
            adjacency_mod.hasEdgeInSideAdj(&graph.graph, fwd, 9999),
        );
    }
}
