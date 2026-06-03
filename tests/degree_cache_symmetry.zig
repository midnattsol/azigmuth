const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const helpers = @import("helpers.zig");

const testing = std.testing;

test "degree: inDegree returns exact published degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    helpers.setPublishedRevDegree(try graph.nodeAt(hub), 42);
    try testing.expectEqual(@as(usize, 42), try graph.inDegree(hub));
}

test "degree: outDegree returns exact published degree" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    helpers.setPublishedFwdDegree(try graph.nodeAt(src), 99);
    try testing.expectEqual(@as(usize, 99), try graph.outDegree(src));
}

test "degree: outDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    helpers.setPublishedFlags(try graph.nodeAt(node), .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = true });
    try testing.expectError(error.InvalidNode, graph.outDegree(node));
}

test "degree: inDegree on removed node returns InvalidNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    helpers.setPublishedFlags(try graph.nodeAt(node), .{ .needs_repair_fwd = false, .needs_repair_rev = false, .removed = true });
    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}
