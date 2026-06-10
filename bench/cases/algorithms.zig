const std = @import("std");
const graphz = @import("graphz");
const harness = @import("../harness.zig");
const Context = graphz.Context;

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

fn fillPreorder(order: []usize, next_idx: *usize, logical_idx: usize, node_count: usize) void {
    if (logical_idx >= node_count) return;
    order[next_idx.*] = logical_idx;
    next_idx.* += 1;
    fillPreorder(order, next_idx, logical_idx * 2 + 1, node_count);
    fillPreorder(order, next_idx, logical_idx * 2 + 2, node_count);
}

fn buildBinaryTreeWithOrder(
    graph: *graphz.Graph,
    allocator: std.mem.Allocator,
    depth: usize,
    order: []const usize,
) ![]graphz.NodeId {
    const node_count: usize = (@as(usize, 1) << @as(u6, @intCast(depth + 1))) - 1;
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    errdefer allocator.free(nodes);

    for (order) |logical_idx| {
        nodes[logical_idx] = try graph.addNode();
    }
    for (0..((@as(usize, 1) << @as(u6, @intCast(depth))) - 1)) |parent_idx| {
        try graph.addEdge(nodes[parent_idx], nodes[parent_idx * 2 + 1], 0, .{});
        try graph.addEdge(nodes[parent_idx], nodes[parent_idx * 2 + 2], 0, .{});
    }
    return nodes;
}

fn buildBinaryTreePreorder(graph: *graphz.Graph, allocator: std.mem.Allocator, depth: usize) ![]graphz.NodeId {
    const node_count: usize = (@as(usize, 1) << @as(u6, @intCast(depth + 1))) - 1;
    const order = try allocator.alloc(usize, node_count);
    defer allocator.free(order);

    var next_idx: usize = 0;
    fillPreorder(order, &next_idx, 0, node_count);
    return buildBinaryTreeWithOrder(graph, allocator, depth, order);
}

fn buildBinaryTreePermuted(graph: *graphz.Graph, allocator: std.mem.Allocator, depth: usize) ![]graphz.NodeId {
    const node_count: usize = (@as(usize, 1) << @as(u6, @intCast(depth + 1))) - 1;
    const order = try allocator.alloc(usize, node_count);
    defer allocator.free(order);

    for (0..node_count) |logical_idx| order[logical_idx] = logical_idx;
    var prng = std.Random.DefaultPrng.init(0x5a17_d35f_9c42_1101);
    const random = prng.random();
    var remaining = node_count;
    while (remaining > 1) {
        remaining -= 1;
        const swap_idx = random.intRangeAtMost(usize, 0, remaining);
        std.mem.swap(usize, &order[remaining], &order[swap_idx]);
    }
    return buildBinaryTreeWithOrder(graph, allocator, depth, order);
}

fn buildChain(graph: *graphz.Graph, allocator: std.mem.Allocator, node_count: usize) ![]graphz.NodeId {
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    for (nodes) |*node| node.* = try graph.addNode();
    for (0..node_count - 1) |node_idx| {
        try graph.addEdge(nodes[node_idx], nodes[node_idx + 1], 0, .{});
    }
    return nodes;
}

fn buildStar(graph: *graphz.Graph, allocator: std.mem.Allocator, node_count: usize) ![]graphz.NodeId {
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    for (nodes) |*node| node.* = try graph.addNode();
    for (1..node_count) |node_idx| {
        try graph.addEdge(nodes[0], nodes[node_idx], 0, .{});
    }
    return nodes;
}

fn runBfsBench(graph: *graphz.Graph, nodes: []const graphz.NodeId, ctx: Context) !harness.Result {
    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    var arena_ctx = ctx;
    arena_ctx.allocator = arena_allocator;

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const order = try snapshot.bfs(nodes[0], arena_ctx);
        if (order.len != nodes.len) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn runDfsBench(graph: *graphz.Graph, nodes: []const graphz.NodeId, ctx: Context) !harness.Result {
    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    var arena_ctx = ctx;
    arena_ctx.allocator = arena_allocator;

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const order = try snapshot.dfs(nodes[0], arena_ctx);
        if (order.len != nodes.len) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

fn benchAlgorithmsBfs(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTreePermuted(graph, allocator, 10);
    defer allocator.free(nodes);
    return runBfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsDfs(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTreePermuted(graph, allocator, 10);
    defer allocator.free(nodes);

    return runDfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsBfsBinaryLevelorder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    return runBfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsDfsBinaryLevelorder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    return runDfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsBfsBinaryPreorder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTreePreorder(graph, allocator, 10);
    defer allocator.free(nodes);

    return runBfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsDfsBinaryPreorder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTreePreorder(graph, allocator, 10);
    defer allocator.free(nodes);

    return runDfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsBfsChain(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildChain(graph, allocator, 2048);
    defer allocator.free(nodes);

    return runBfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsDfsChain(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildChain(graph, allocator, 2048);
    defer allocator.free(nodes);

    return runDfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsBfsStar(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildStar(graph, allocator, 2048);
    defer allocator.free(nodes);

    return runBfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsDfsStar(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildStar(graph, allocator, 2048);
    defer allocator.free(nodes);

    return runDfsBench(graph, nodes, .{ .allocator = allocator });
}

fn benchAlgorithmsHasCycleAcyclic(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const nodes = try buildBinaryTree(graph, allocator, 10);
    defer allocator.free(nodes);

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(.{ .allocator = arena_allocator });
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

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(.{ .allocator = arena_allocator });
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

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        const has_cycle = try snapshot.hasCycle(.{ .allocator = arena_allocator });
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
        var snapshot = try graph.snapshot(.{ .allocator = allocator });
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    const iterations: usize = 20;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const bfs_order = try snapshot.bfs(nodes[0], .{ .allocator = arena_allocator });
        if (bfs_order.len != nodes.len) return error.CorruptGraph;

        _ = arena.reset(.retain_capacity);
        const dfs_order = try snapshot.dfs(nodes[0], .{ .allocator = arena_allocator });
        if (dfs_order.len != nodes.len) return error.CorruptGraph;

        _ = arena.reset(.retain_capacity);
        const has_cycle = try snapshot.hasCycle(.{ .allocator = arena_allocator });
        if (has_cycle) return error.CorruptGraph;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = iterations, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "algorithms.bfs", .run = benchAlgorithmsBfs },
    .{ .name = "algorithms.dfs", .run = benchAlgorithmsDfs },
    .{ .name = "algorithms.bfs_complete_binary_levelorder", .run = benchAlgorithmsBfsBinaryLevelorder },
    .{ .name = "algorithms.dfs_complete_binary_levelorder", .run = benchAlgorithmsDfsBinaryLevelorder },
    .{ .name = "algorithms.bfs_complete_binary_preorder", .run = benchAlgorithmsBfsBinaryPreorder },
    .{ .name = "algorithms.dfs_complete_binary_preorder", .run = benchAlgorithmsDfsBinaryPreorder },
    .{ .name = "algorithms.bfs_chain", .run = benchAlgorithmsBfsChain },
    .{ .name = "algorithms.dfs_chain", .run = benchAlgorithmsDfsChain },
    .{ .name = "algorithms.bfs_star", .run = benchAlgorithmsBfsStar },
    .{ .name = "algorithms.dfs_star", .run = benchAlgorithmsDfsStar },
    .{ .name = "algorithms.hascycle_acyclic", .run = benchAlgorithmsHasCycleAcyclic },
    .{ .name = "algorithms.hascycle_cyclic", .run = benchAlgorithmsHasCycleCyclic },
    .{ .name = "algorithms.hascycle_cyclic_early", .run = benchAlgorithmsHasCycleCyclicEarly },
    .{ .name = "snapshot.capture", .run = benchSnapshotCapture },
    .{ .name = "snapshot.bundle_forward_queries", .run = benchSnapshotBundleForwardQueries },
};
