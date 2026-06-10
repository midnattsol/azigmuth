//! Workload-shaped benchmarks: mutation patterns, churn, and point reads.
//! These cases exist so layout/contract changes always have before/after
//! numbers for the access patterns that matter, not just micro-paths.

const std = @import("std");
const graphz = @import("graphz");
const harness = @import("../harness.zig");

/// Deterministic LCG so runs are comparable across branches.
const Rng = struct {
    state: u64 = 0x9E37_79B9_7F4A_7C15,

    fn next(self: *Rng) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }

    fn upTo(self: *Rng, bound: usize) usize {
        return @intCast(self.next() % @as(u64, @intCast(bound)));
    }
};

fn benchTinyChurn(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const pair_count: usize = 512;
    const cycles: usize = 8;
    var nodes: [2 * pair_count]graphz.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

    const start_ns = harness.nowNs();
    for (0..cycles) |_| {
        for (0..pair_count) |pair_idx| {
            try graph.addEdge(nodes[2 * pair_idx], nodes[2 * pair_idx + 1], 0, .{});
        }
        for (0..pair_count) |pair_idx| {
            _ = try graph.removeEdge(nodes[2 * pair_idx], nodes[2 * pair_idx + 1]);
        }
        graph.reclaimRetired();
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    // Reuse keeps tiny allocation bounded; report so regressions are visible.
    const stats = try graph.storageStats();
    std.debug.print("  [tiny_churn] tiny_fwd_allocated={} tiny_rev_allocated={} (pairs={} cycles={})\n", .{
        stats.tiny_fwd_allocated, stats.tiny_rev_allocated, pair_count, cycles,
    });

    try graph.validate();
    return .{ .ops = pair_count * cycles * 2, .elapsed_ns = elapsed_ns };
}

fn benchAddEdgeMonotonic(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const edge_count: usize = 4096;
    const source = try graph.addNode();
    const destinations = try allocator.alloc(graphz.NodeId, edge_count);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    const start_ns = harness.nowNs();
    for (destinations) |destination| try graph.addEdge(source, destination, 0, .{});
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = edge_count, .elapsed_ns = elapsed_ns };
}

fn benchAddEdgeRandomOrder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const edge_count: usize = 4096;
    const source = try graph.addNode();
    const destinations = try allocator.alloc(graphz.NodeId, edge_count);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    // Deterministic shuffle: every insertion lands at a random sorted position.
    var rng = Rng{};
    var shuffle_idx: usize = edge_count;
    while (shuffle_idx > 1) {
        shuffle_idx -= 1;
        const swap_idx = rng.upTo(shuffle_idx + 1);
        std.mem.swap(graphz.NodeId, &destinations[shuffle_idx], &destinations[swap_idx]);
    }

    const start_ns = harness.nowNs();
    for (destinations) |destination| try graph.addEdge(source, destination, 0, .{});
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = edge_count, .elapsed_ns = elapsed_ns };
}

fn benchPointReadSnapshot(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    // Sparse graph: the snapshot capture cost is dominated by node count,
    // which is exactly what a point read should NOT have to pay.
    const node_count: usize = 100_000;
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    defer allocator.free(nodes);
    for (nodes) |*node| node.* = try graph.addNode();
    for (0..64) |neighbor_idx| {
        try graph.addEdge(nodes[0], nodes[neighbor_idx + 1], 0, .{});
    }

    const ops: usize = 32;
    var seen: usize = 0;
    const start_ns = harness.nowNs();
    for (0..ops) |_| {
        var snapshot = try graph.snapshot(.{ .allocator = allocator });
        defer snapshot.deinit();
        var it = try snapshot.neighbors(nodes[0]);
        while (it.next() != null) seen += 1;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    if (seen != 64 * ops) return error.CorruptGraph;
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchRemoveEdgeRandomOrder(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const edge_count: usize = 4096;
    const source = try graph.addNode();
    const destinations = try allocator.alloc(graphz.NodeId, edge_count);
    defer allocator.free(destinations);
    for (destinations) |*destination| {
        destination.* = try graph.addNode();
        try graph.addEdge(source, destination.*, 0, .{});
    }

    var rng = Rng{};
    var shuffle_idx: usize = edge_count;
    while (shuffle_idx > 1) {
        shuffle_idx -= 1;
        const swap_idx = rng.upTo(shuffle_idx + 1);
        std.mem.swap(graphz.NodeId, &destinations[shuffle_idx], &destinations[swap_idx]);
    }

    const ops: usize = edge_count / 2;
    const start_ns = harness.nowNs();
    for (destinations[0..ops]) |destination| {
        _ = graph.removeEdge(source, destination) catch |err| switch (err) {
            error.RepairRequired => repaired: {
                _ = try graph.repairNode(source);
                break :repaired try graph.removeEdge(source, destination);
            },
            else => return err,
        };
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchPointReadSession(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const node_count: usize = 100_000;
    const nodes = try allocator.alloc(graphz.NodeId, node_count);
    defer allocator.free(nodes);
    for (nodes) |*node| node.* = try graph.addNode();
    for (0..64) |neighbor_idx| {
        try graph.addEdge(nodes[0], nodes[neighbor_idx + 1], 0, .{});
    }

    const ops: usize = 4096;
    var seen: usize = 0;
    const start_ns = harness.nowNs();
    for (0..ops) |_| {
        var session = try graph.readSession(allocator);
        defer session.deinit();
        var it = try session.neighbors(nodes[0]);
        defer it.deinit();
        while (it.next() != null) seen += 1;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    if (seen != 64 * ops) return error.CorruptGraph;
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "workload.point_read_session", .run = benchPointReadSession },
    .{ .name = "workload.tiny_churn", .run = benchTinyChurn },
    .{ .name = "workload.addedge_monotonic", .run = benchAddEdgeMonotonic },
    .{ .name = "workload.addedge_random_order", .run = benchAddEdgeRandomOrder },
    .{ .name = "workload.removeedge_random_order", .run = benchRemoveEdgeRandomOrder },
    .{ .name = "workload.point_read_snapshot", .run = benchPointReadSnapshot },
};
