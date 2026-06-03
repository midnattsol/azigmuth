const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

fn expectNoViolations(graph: *graph_mod.Graph, allocator: std.mem.Allocator) !void {
    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    if (violations.len != 0) {
        std.debug.print("unexpected violations: {any}\n", .{violations});
    }
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "mixed sequence: add, remove, repair, removeNode, add leaves a clean graph" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    var nodes: [10]graph_mod.NodeId = undefined;
    for (0..10) |idx| {
        nodes[idx] = try graph.addNode();
    }
    for (0..10) |i| {
        for (0..10) |j| {
            if (i != j) try graph.addEdge(nodes[i], nodes[j], 0, 0);
        }
    }
    try expectNoViolations(&graph, allocator);

    _ = try graph.removeEdge(nodes[0], nodes[5]);
    _ = try graph.removeEdge(nodes[1], nodes[5]);
    _ = try graph.removeEdge(nodes[2], nodes[5]);
    try expectNoViolations(&graph, allocator);

    try graph.repairNode(nodes[5]);
    try expectNoViolations(&graph, allocator);

    try graph.removeNode(nodes[5]);
    try expectNoViolations(&graph, allocator);

    const replacement = try graph.addNode();
    try graph.addEdge(replacement, nodes[0], 0, 0);
    try graph.addEdge(replacement, nodes[1], 0, 0);
    try expectNoViolations(&graph, allocator);

    try graph.validate();
}

test "mixed sequence: alternating addNode and addEdge with periodic repair stays clean" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    var nodes: [6]graph_mod.NodeId = undefined;
    for (0..6) |idx| {
        nodes[idx] = try graph.addNode();
    }

    var state: u64 = 12345;
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        for (0..6) |i| {
            for (0..6) |j| {
                if (i == j) continue;
                state = state *% 6364136223846793005 +% 1442695040888963407;
                const relation: u16 = @intCast(state & 0xFFFF);
                _ = graph.addEdge(nodes[i], nodes[j], relation, 0) catch {};
            }
        }
        for (0..6) |node_index| {
            try graph.repairNode(nodes[node_index]);
        }
        try expectNoViolations(&graph, allocator);
    }

    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "mixed sequence: addEdge, removeEdge, removeNode, addNode with the recycled slot" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    const c = try graph.addNode();

    try graph.addEdge(a, b, 0, 0);
    try graph.addEdge(a, c, 0, 0);
    try graph.addEdge(b, c, 0, 0);
    try expectNoViolations(&graph, allocator);

    _ = try graph.removeEdge(b, c);
    try expectNoViolations(&graph, allocator);

    try graph.removeNode(b);
    try expectNoViolations(&graph, allocator);

    const fresh = try graph.addNode();
    try graph.addEdge(fresh, c, 0, 0);
    try expectNoViolations(&graph, allocator);

    const d = try graph.addNode();
    try graph.addEdge(a, d, 0, 0);
    try graph.addEdge(d, fresh, 0, 0);
    try expectNoViolations(&graph, allocator);

    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    try testing.expectEqual(@as(u64, 4), graph.edgeCount());
}
