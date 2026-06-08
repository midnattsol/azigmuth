const std = @import("std");
const graphz = @import("graphz");
const harness = @import("../harness.zig");

fn prefillSource(graph: *graphz.Graph, source: graphz.NodeId, count: usize, allocator: std.mem.Allocator) ![]graphz.NodeId {
    const destinations = try allocator.alloc(graphz.NodeId, count);
    for (destinations) |*destination| {
        destination.* = try graph.addNode();
        try graph.addEdge(source, destination.*, 0, .{});
    }
    return destinations;
}

fn benchAddEdgePhaseSingleBlock(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const ops: usize = 64;
    const destinations = try allocator.alloc(graphz.NodeId, ops);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    const start_ns = harness.nowNs();
    for (destinations) |destination| try graph.addEdge(source, destination, 0, .{});
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchAddEdgePhaseGrouped(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const prefilled = try prefillSource(graph, source, 64, allocator);
    defer allocator.free(prefilled);

    const ops: usize = 64;
    const destinations = try allocator.alloc(graphz.NodeId, ops);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    const start_ns = harness.nowNs();
    for (destinations) |destination| try graph.addEdge(source, destination, 0, .{});
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchAddEdgePhaseSuffixCow(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const prefilled = try prefillSource(graph, source, 256, allocator);
    defer allocator.free(prefilled);

    const ops: usize = 64;
    const destinations = try allocator.alloc(graphz.NodeId, ops);
    defer allocator.free(destinations);
    for (destinations) |*destination| destination.* = try graph.addNode();

    const start_ns = harness.nowNs();
    for (destinations) |destination| try graph.addEdge(source, destination, 0, .{});
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchRemoveEdgeTail(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const edge_count: usize = 8_192;
    const destinations = try allocator.alloc(graphz.NodeId, edge_count);
    defer allocator.free(destinations);

    for (destinations) |*destination| {
        destination.* = try graph.addNode();
        try graph.addEdge(source, destination.*, 0, .{});
    }

    const ops: usize = edge_count / 2;
    const start_ns = harness.nowNs();
    for (0..ops) |offset| {
        const destination = destinations[edge_count - 1 - offset];
        _ = try graph.removeEdge(source, destination);
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

fn benchRemoveEdgeRepairRequired(allocator: std.mem.Allocator) !harness.Result {
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const edge_count: usize = 65;
    const destinations = try allocator.alloc(graphz.NodeId, edge_count);
    defer allocator.free(destinations);

    for (destinations) |*destination| {
        destination.* = try graph.addNode();
        try graph.addEdge(source, destination.*, 0, .{});
    }

    const ops: usize = 1024;
    const start_ns = harness.nowNs();
    for (0..ops) |_| {
        _ = graph.removeEdge(source, destinations[0]) catch |err| {
            if (err == error.RepairRequired) continue;
            return err;
        };
        return error.ExpectedRepairRequired;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    return .{ .ops = ops, .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "mutation.addedge_phase_single_block", .run = benchAddEdgePhaseSingleBlock },
    .{ .name = "mutation.addedge_phase_grouped", .run = benchAddEdgePhaseGrouped },
    .{ .name = "mutation.addedge_phase_suffix_cow", .run = benchAddEdgePhaseSuffixCow },
    .{ .name = "mutation.removeedge_tail", .run = benchRemoveEdgeTail },
    .{ .name = "mutation.removeedge_repairrequired", .run = benchRemoveEdgeRepairRequired },
};
