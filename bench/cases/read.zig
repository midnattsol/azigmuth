const std = @import("std");
const graphz = @import("graphz");
const harness = @import("../harness.zig");

const scan_iterations: usize = 32;
const destination_count: usize = 4096;

fn benchSnapshotNeighborsScanClean(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..destination_count) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var seen: usize = 0;
    const start_ns = harness.nowNs();
    for (0..scan_iterations) |_| {
        var it = try snapshot.neighbors(source);
        while (it.next() != null) seen += 1;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    if (seen != destination_count * scan_iterations) return error.CorruptGraph;
    return .{ .ops = destination_count * scan_iterations, .elapsed_ns = elapsed_ns };
}

fn benchSnapshotNeighborsScanTombstones(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destinations = try allocator.alloc(graphz.NodeId, destination_count);
    defer allocator.free(destinations);

    for (destinations) |*destination| {
        destination.* = try graph.addNode();
        try graph.addEdge(source, destination.*, 0, .{});
    }
    for (destinations, 0..) |destination, destination_idx| {
        if (destination_idx % 4 == 0) _ = try graph.removeNode(destination);
    }

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var visible_seen: usize = 0;
    const start_ns = harness.nowNs();
    for (0..scan_iterations) |_| {
        var it = try snapshot.neighbors(source);
        while (it.next() != null) visible_seen += 1;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    const visible_per_scan = destination_count - destination_count / 4;
    if (visible_seen != visible_per_scan * scan_iterations) return error.CorruptGraph;
    return .{ .ops = destination_count * scan_iterations, .elapsed_ns = elapsed_ns };
}

fn benchSnapshotOutDegree(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..destination_count) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    var total: usize = 0;
    const start_ns = harness.nowNs();
    for (0..scan_iterations) |_| {
        total += try snapshot.outDegree(source);
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    if (total != destination_count * scan_iterations) return error.CorruptGraph;
    return .{ .ops = scan_iterations, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "snapshot.neighbors_scan_clean", .run = benchSnapshotNeighborsScanClean },
    .{ .name = "snapshot.neighbors_scan_tombstones", .run = benchSnapshotNeighborsScanTombstones },
    .{ .name = "snapshot.outdegree", .run = benchSnapshotOutDegree },
};
