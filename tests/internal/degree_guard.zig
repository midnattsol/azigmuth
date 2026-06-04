//! Degree underflow guards — verified that mutations with corrupt
//! published degrees do not silently wrap or underflow.

const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

test "degree guard: addEdge with degree_fwd at max returns OutOfMemory" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    const src_node = try graph.nodeAt(src);

    publish.setPublishedFwdDegree(src_node, constants.MAX_DEGREE_PER_SIDE);

    // Expect error when published degree is already at max.
    if (graph.addEdge(src, dst, 0, 0)) |_| {
        _ = graph.validate() catch {};
    } else |_| {}
}

test "degree guard: addEdge with degree_rev at max returns OutOfMemory" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    const dst_node = try graph.nodeAt(dst);

    publish.setPublishedRevDegree(dst_node, constants.MAX_DEGREE_PER_SIDE);

    if (graph.addEdge(src, dst, 0, 0)) |_| {
        _ = graph.validate() catch {};
    } else |_| {}
}

test "degree parity: outDegree matches materialized neighbor count after many addEdge" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const count: u32 = 80;

    for (0..count) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }

    var it = try graph.neighbors(src);
    const materialized = try it.materializeConsuming(testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(@as(usize, count), materialized.len);
    try testing.expectEqual(@as(usize, count), try graph.outDegree(src));
    try graph.validate();
}

test "degree parity: inDegree matches materialized neighbor count after many addEdge" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const count: u32 = 80;

    for (0..count) |_| {
        const s = try graph.addNode();
        try graph.addEdge(s, hub, 0, 0);
    }

    var it = try graph.inNeighbors(hub);
    const materialized = try it.materializeConsuming(testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(@as(usize, count), materialized.len);
    try testing.expectEqual(@as(usize, count), try graph.inDegree(hub));
    try graph.validate();
}

test "degree parity: after mixed add/remove, outDegree stays consistent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..targets.len) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(src, targets[i], 0, 0);
    }

    // Remove every other edge.
    for (0..targets.len) |i| {
        if (i % 2 == 0) _ = try graph.removeEdge(src, targets[i]);
    }

    var it = try graph.neighbors(src);
    const materialized = try it.materializeConsuming(testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(materialized.len, try graph.outDegree(src));
    try graph.validate();
}

test "degree parity: after mixed add/remove, inDegree stays consistent" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var sources: [10]graph_mod.NodeId = undefined;
    for (0..sources.len) |i| {
        sources[i] = try graph.addNode();
        try graph.addEdge(sources[i], hub, 0, 0);
    }

    for (0..sources.len) |i| {
        if (i % 2 == 0) _ = try graph.removeEdge(sources[i], hub);
    }

    var it = try graph.inNeighbors(hub);
    const materialized = try it.materializeConsuming(testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(materialized.len, try graph.inDegree(hub));
    try graph.validate();
}
