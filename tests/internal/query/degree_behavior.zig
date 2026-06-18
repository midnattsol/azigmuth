//! Degree behavior tests cover three related concerns:
//! exact published degree reads, degree limits during mutation, and parity
//! between degree APIs and neighbor iteration.

const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const publish = @import("publish");

const testing = std.testing;

test "degree behavior: inDegree returns exact published degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    publish.setPublishedRevDegree(try graph.nodeAt(hub), 42);
    publish.syncPublicationStateToPublished(&graph, hub.index);
    try testing.expectEqual(@as(usize, 42), try graph.inDegree(hub));
}

test "degree behavior: outDegree returns exact published degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    publish.setPublishedFwdDegree(try graph.nodeAt(source), 99);
    publish.syncPublicationStateToPublished(&graph, source.index);
    try testing.expectEqual(@as(usize, 99), try graph.outDegree(source));
}

test "degree behavior: outDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    publish.setPublishedFlags(try graph.nodeAt(node), .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = true });
    publish.syncPublicationStateToPublished(&graph, node.index);
    try testing.expectError(error.InvalidNode, graph.outDegree(node));
}

test "degree behavior: inDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    publish.setPublishedFlags(try graph.nodeAt(node), .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = true });
    publish.syncPublicationStateToPublished(&graph, node.index);
    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}

test "degree behavior: addEdge with degree_fwd at max returns DegreeLimitReached" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    publish.setPublishedFwdDegreeExact(&graph, source.index, constants.MAX_DEGREE_PER_SIDE);

    try testing.expectError(error.DegreeLimitReached, graph.addEdge(source, destination, 0, 0));
}

test "degree behavior: addEdge with degree_rev at max returns DegreeLimitReached" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    publish.setPublishedRevDegreeExact(&graph, destination.index, constants.MAX_DEGREE_PER_SIDE);

    try testing.expectError(error.DegreeLimitReached, graph.addEdge(source, destination, 0, 0));
}

test "degree behavior: outDegree matches materialized neighbor count after many addEdge" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const count: u32 = 80;

    for (0..count) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, 0);
    }

    var iterator = try graph.neighbors(source);
    const materialized = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(@as(usize, count), materialized.len);
    try testing.expectEqual(@as(usize, count), try graph.outDegree(source));
    try graph.validate();
}

test "degree behavior: inDegree matches materialized neighbor count after many addEdge" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const count: u32 = 80;

    for (0..count) |_| {
        const source = try graph.addNode();
        try graph.addEdge(source, hub, 0, 0);
    }

    var iterator = try graph.inNeighbors(hub);
    const materialized = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(@as(usize, count), materialized.len);
    try testing.expectEqual(@as(usize, count), try graph.inDegree(hub));
    try graph.validate();
}

test "degree behavior: outDegree stays consistent after mixed add and remove" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [10]graph_mod.NodeId = undefined;
    for (0..targets.len) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    for (0..targets.len) |target_idx| {
        if (target_idx % 2 == 0) _ = try graph.removeEdge(source, targets[target_idx]);
    }

    var iterator = try graph.neighbors(source);
    const materialized = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(materialized.len, try graph.outDegree(source));
    try graph.validate();
}

test "degree behavior: inDegree stays consistent after mixed add and remove" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var sources: [10]graph_mod.NodeId = undefined;
    for (0..sources.len) |source_idx| {
        sources[source_idx] = try graph.addNode();
        try graph.addEdge(sources[source_idx], hub, 0, 0);
    }

    for (0..sources.len) |source_idx| {
        if (source_idx % 2 == 0) _ = try graph.removeEdge(sources[source_idx], hub);
    }

    var iterator = try graph.inNeighbors(hub);
    const materialized = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(materialized);

    try testing.expectEqual(materialized.len, try graph.inDegree(hub));
    try graph.validate();
}
