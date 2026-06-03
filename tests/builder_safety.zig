//! GraphBuilder safety — edge_key hygiene, freeze correctness,
//! and degree/edge_count coherence after freeze.

const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;

const testing = std.testing;

test "builder: addEdge with invalid NodeId does not leave edge_key orphaned" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const valid = try builder.addNode();
    const invalid = graph_mod.NodeId{ .index = 9999 };

    _ = builder.addEdge(valid, invalid, 0, 0) catch {};

    // The invalid key must not persist in edge_keys.
    const key = (@as(u64, valid.index) << 32) | invalid.index;
    try testing.expect(!builder.edge_keys.contains(key));

    // Builder should still be usable for valid edges.
    const other = try builder.addNode();
    try builder.addEdge(valid, other, 0, 0);

    var frozen = try builder.freeze();
    defer frozen.deinit();

    try testing.expectEqual(@as(u64, 1), frozen.edgeCount());
    try frozen.validate();
}

test "builder: multiple invalid addEdge calls do not leak keys" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    const valid = try builder.addNode();
    const invalid_nodes = [_]graph_mod.NodeId{
        .{ .index = 9999 },
        .{ .index = 9998 },
        .{ .index = 9997 },
    };

    for (invalid_nodes[0..]) |inv| {
        _ = builder.addEdge(valid, inv, 0, 0) catch {};
    }

    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(builder.edge_keys.count())));

    // Valid edges still work.
    const dst = try builder.addNode();
    try builder.addEdge(valid, dst, 0, 0);

    var frozen = try builder.freeze();
    defer frozen.deinit();
    try testing.expectEqual(@as(u64, 1), frozen.edgeCount());
    try frozen.validate();
}

test "builder: freeze with many nodes and edges produces consistent graph" {
    const allocator = std.heap.page_allocator;
    var builder = try graph_mod.GraphBuilder.init(allocator);

    const node_count: usize = 50;
    var nodes: [50]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        nodes[i] = try builder.addNode();
    }

    var edge_count: usize = 0;
    for (0..node_count) |i| {
        for (0..@min(i, 5)) |j| {
            if (i != j) {
                try builder.addEdge(nodes[i], nodes[j], 0, 0);
                edge_count += 1;
            }
        }
    }

    var frozen = try builder.freeze();
    defer frozen.deinit();

    try testing.expectEqual(@as(usize, node_count), frozen.nodeCount());
    try testing.expectEqual(@as(u64, @intCast(edge_count)), frozen.edgeCount());

    // Every node should have correct outDegree.
    for (0..node_count) |i| {
        const expected: usize = @min(i, 5);
        try testing.expectEqual(expected, try frozen.outDegree(nodes[i]));
    }

    try frozen.validate();
}

test "builder: freeze with nodes but zero edges produces clean graph" {
    var builder = try graph_mod.GraphBuilder.init(testing.allocator);
    defer builder.deinit();

    for (0..20) |_| _ = try builder.addNode();

    var frozen = try builder.freeze();
    defer frozen.deinit();

    try testing.expectEqual(@as(usize, 20), frozen.nodeCount());
    try testing.expectEqual(@as(u64, 0), frozen.edgeCount());

    for (0..20) |i| {
        try testing.expectEqual(@as(usize, 0), try frozen.outDegree(.{ .index = @intCast(i) }));
        try testing.expectEqual(@as(usize, 0), try frozen.inDegree(.{ .index = @intCast(i) }));
    }

    try frozen.validate();
}

test "builder: freeze produces zero-violation debugValidate" {
    const allocator = std.heap.page_allocator;
    var builder = try graph_mod.GraphBuilder.init(allocator);

    for (0..40) |_| _ = try builder.addNode();

    for (0..40) |i| {
        // Each node i has edges to nodes [0 .. i-1].
        for (0..i) |j| {
            try builder.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }

    var frozen = try builder.freeze();
    defer frozen.deinit();

    const violations = try frozen.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
