const std = @import("std");
const azigmuth = @import("azigmuth");
const harness = @import("../harness.zig");

const scan_iterations: usize = 32;
const destination_count: usize = 4096;
const sparse_node_count: usize = 131072;
const sparse_edge_count: usize = 1024;

fn buildSparseGraph(graph: *azigmuth.Graph) !void {
    var previous: ?azigmuth.NodeId = null;
    for (0..sparse_node_count) |node_idx| {
        const node = try graph.addNode();
        if (node_idx < sparse_edge_count) {
            if (previous) |source| try graph.addEdge(source, node, 0, .{});
            previous = node;
        }
    }
}

fn benchSnapshotNeighborsScanClean(allocator: std.mem.Allocator) !harness.Result {
    var graph = try azigmuth.Graph.init(allocator);
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
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destinations = try allocator.alloc(azigmuth.NodeId, destination_count);
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
    var graph = try azigmuth.Graph.init(allocator);
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

fn benchSnapshotCaptureSparseEmptyHeavy(allocator: std.mem.Allocator) !harness.Result {
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    try buildSparseGraph(graph);

    const iterations: usize = 8;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        var snapshot = try graph.snapshot(.{ .allocator = allocator });
        snapshot.deinit();
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = sparse_node_count * iterations, .elapsed_ns = elapsed_ns };
}

fn benchSnapshotOutEdgesMultigraph(allocator: std.mem.Allocator) !harness.Result {
    var graph = try azigmuth.Graph.initWithOptions(allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const duplicate_count: usize = 1024;
    const destination_count_local: usize = 256;
    const destinations = try allocator.alloc(azigmuth.NodeId, destination_count_local);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    for (0..duplicate_count) |edge_idx| {
        const destination = destinations[edge_idx % destination_count_local];
        _ = try graph.addEdgeWithId(source, destination, 0, .{});
    }

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();

    const iterations: usize = 16;
    var seen: usize = 0;
    const start_ns = harness.nowNs();
    for (0..iterations) |_| {
        var it = try snapshot.outEdges(source);
        while (it.next() != null) seen += 1;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    if (seen != duplicate_count * iterations) return error.CorruptGraph;
    return .{ .ops = duplicate_count * iterations, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "snapshot.neighbors_scan_clean", .run = benchSnapshotNeighborsScanClean },
    .{ .name = "snapshot.neighbors_scan_tombstones", .run = benchSnapshotNeighborsScanTombstones },
    .{ .name = "snapshot.outdegree", .run = benchSnapshotOutDegree },
    .{ .name = "snapshot.outedges_multigraph", .run = benchSnapshotOutEdgesMultigraph },
};
