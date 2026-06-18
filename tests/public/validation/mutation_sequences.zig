const std = @import("std");
const azigmuth = @import("azigmuth");
const testing = std.testing;

fn expectNoViolations(graph: *azigmuth.Graph, allocator: std.mem.Allocator) !void {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    if (violations.len != 0) {
        std.debug.print("unexpected violations: {any}\n", .{violations});
    }
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "mixed sequence: add, remove, repair, removeNode, add leaves a clean graph" {
    const allocator = std.heap.page_allocator;
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    var nodes: [10]azigmuth.NodeId = undefined;
    for (0..10) |idx| {
        nodes[idx] = try graph.addNode();
    }
    for (0..10) |source_idx| {
        for (0..10) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{});
        }
    }
    try expectNoViolations(graph, allocator);

    _ = try graph.removeEdge(nodes[0], nodes[5]);
    _ = try graph.removeEdge(nodes[1], nodes[5]);
    _ = try graph.removeEdge(nodes[2], nodes[5]);
    try expectNoViolations(graph, allocator);

    _ = try graph.repairNode(nodes[5]);
    try expectNoViolations(graph, allocator);

    _ = try graph.removeNode(nodes[5]);
    try expectNoViolations(graph, allocator);

    const replacement = try graph.addNode();
    try graph.addEdge(replacement, nodes[0], 0, .{});
    try graph.addEdge(replacement, nodes[1], 0, .{});
    try expectNoViolations(graph, allocator);

    try graph.validate();
}

test "mixed sequence: alternating addNode and addEdge with periodic repair stays clean" {
    const allocator = std.heap.page_allocator;
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    var nodes: [6]azigmuth.NodeId = undefined;
    for (0..6) |idx| {
        nodes[idx] = try graph.addNode();
    }

    var state: u64 = 12345;
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        for (0..6) |source_idx| {
            for (0..6) |destination_idx| {
                if (source_idx == destination_idx) continue;
                state = state *% 6364136223846793005 +% 1442695040888963407;
                const relation: u16 = @intCast(state & 0xFFFF);
                _ = graph.addEdge(nodes[source_idx], nodes[destination_idx], relation, .{}) catch {};
            }
        }
        for (0..6) |node_idx| {
            _ = try graph.repairNode(nodes[node_idx]);
        }
        try expectNoViolations(graph, allocator);
    }

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "mixed sequence: addEdge, removeEdge, removeNode, addNode with the recycled slot" {
    const allocator = std.heap.page_allocator;
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const removed = try graph.addNode();
    const destination = try graph.addNode();

    try graph.addEdge(source, removed, 0, .{});
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(removed, destination, 0, .{});
    try expectNoViolations(graph, allocator);

    _ = try graph.removeEdge(removed, destination);
    try expectNoViolations(graph, allocator);

    _ = try graph.removeNode(removed);
    try expectNoViolations(graph, allocator);

    const fresh = try graph.addNode();
    try graph.addEdge(fresh, destination, 0, .{});
    try expectNoViolations(graph, allocator);

    const extra_destination = try graph.addNode();
    try graph.addEdge(source, extra_destination, 0, .{});
    try graph.addEdge(extra_destination, fresh, 0, .{});
    try expectNoViolations(graph, allocator);

    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    try testing.expectEqual(@as(u64, 4), graph.edgeCount());
}
