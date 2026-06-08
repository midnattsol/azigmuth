const std = @import("std");
const graphz = @import("graphz");
const harness = @import("../harness.zig");

fn buildBinaryTree(graph: *graphz.Graph, allocator: std.mem.Allocator, depth: usize) ![]graphz.NodeId {
    const node_count: usize = (@as(usize, 1) << @as(u6, @intCast(depth + 1))) - 1;
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    for (nodes) |*node| node.* = try graph.addNode();
    for (0..((@as(usize, 1) << @as(u6, @intCast(depth))) - 1)) |parent_idx| {
        try graph.addEdge(nodes[parent_idx], nodes[parent_idx * 2 + 1], 0, .{});
        try graph.addEdge(nodes[parent_idx], nodes[parent_idx * 2 + 2], 0, .{});
    }
    return nodes;
}

fn benchAlgorithmsBfs(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const order = try snapshot.bfs(nodes[0], allocator);
        if (order.len != nodes.len) return error.CorruptGraph;
        allocator.free(order);
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchAlgorithmsDfs(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const order = try snapshot.dfs(nodes[0], allocator);
        if (order.len != nodes.len) return error.CorruptGraph;
        allocator.free(order);
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchAlgorithmsHasCycleAcyclic(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(allocator);
        if (has_cycle) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchAlgorithmsHasCycleCyclic(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);
    try graph.addEdge(nodes[nodes.len - 1], nodes[0], 0, .{});

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(allocator);
        if (!has_cycle) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchAlgorithmsHasCycleCyclicEarly(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);
    try graph.addEdge(nodes[1], nodes[0], 0, .{});

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(allocator);
        if (!has_cycle) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchSnapshotCapture(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        var snapshot = try graph.snapshot(allocator);
        snapshot.deinit();
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchSnapshotBundleForwardQueries(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const bfs_order = try snapshot.bfs(nodes[0], allocator);
        if (bfs_order.len != nodes.len) return error.CorruptGraph;
        allocator.free(bfs_order);

        const dfs_order = try snapshot.dfs(nodes[0], allocator);
        if (dfs_order.len != nodes.len) return error.CorruptGraph;
        allocator.free(dfs_order);

        const has_cycle = try snapshot.hasCycle(allocator);
        if (has_cycle) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "algorithms.bfs", .run = benchAlgorithmsBfs },
    .{ .name = "algorithms.dfs", .run = benchAlgorithmsDfs },
    .{ .name = "algorithms.hascycle_acyclic", .run = benchAlgorithmsHasCycleAcyclic },
    .{ .name = "algorithms.hascycle_cyclic", .run = benchAlgorithmsHasCycleCyclic },
    .{ .name = "algorithms.hascycle_cyclic_early", .run = benchAlgorithmsHasCycleCyclicEarly },
    .{ .name = "snapshot.capture", .run = benchSnapshotCapture },
    .{ .name = "snapshot.bundle_forward_queries", .run = benchSnapshotBundleForwardQueries },
};
