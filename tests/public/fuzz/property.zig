const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

fn shrinkAndReplay(
    allocator: std.mem.Allocator,
    ops: []const Op,
    initial_nodes: usize,
) error{OutOfMemory}!void {
    if (ops.len <= 1) return;

    var candidate = ops;
    while (candidate.len > 1) {
        var removed_any = false;
        var prefix_len: usize = 1;
        while (prefix_len < candidate.len) {
            const reduced = candidate[0..prefix_len];
            var graph = try azigmuth.Graph.init(allocator);
            errdefer graph.deinit();

            var nodes: [16]azigmuth.NodeId = undefined;
            var node_idx: usize = 0;
            while (node_idx < initial_nodes and node_idx < 16) : (node_idx += 1) {
                nodes[node_idx] = try graph.addNode();
            }

            var passed = true;
            for (reduced) |op| {
                const source_idx = op.source % @min(initial_nodes, 16);
                const destination_idx = op.destination % @min(initial_nodes, 16);
                if (source_idx == destination_idx) continue;
                if (graph.hasNode(nodes[source_idx]) and graph.hasNode(nodes[destination_idx])) {
                    switch (op.kind) {
                        .add => {
                            if (graph.addEdge(nodes[source_idx], nodes[destination_idx], op.rel, @bitCast(op.flags))) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .remove => {
                            if (graph.removeEdge(nodes[source_idx], nodes[destination_idx])) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .repair_node => {
                            if (graph.repairNode(nodes[source_idx])) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .remove_node => {
                            if (graph.removeNode(nodes[source_idx])) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                    }
                }
            }

            if (passed) {
                candidate = reduced;
                removed_any = true;
            } else {
                prefix_len += 1;
            }
        }

        if (!removed_any) break;
    }

    var graph2 = try azigmuth.Graph.init(allocator);
    defer graph2.deinit();

    var nodes2: [16]azigmuth.NodeId = undefined;
    var node_idx: usize = 0;
    while (node_idx < initial_nodes and node_idx < 16) : (node_idx += 1) {
        nodes2[node_idx] = try graph2.addNode();
    }

    for (ops) |op| {
        const source_idx = op.source % @min(initial_nodes, 16);
        const destination_idx = op.destination % @min(initial_nodes, 16);
        if (source_idx == destination_idx) continue;
        if (graph2.hasNode(nodes2[source_idx]) and graph2.hasNode(nodes2[destination_idx])) {
            switch (op.kind) {
                .add => {
                    if (graph2.addEdge(nodes2[source_idx], nodes2[destination_idx], op.rel, @bitCast(op.flags))) |_| {} else |_| break;
                },
                .remove => {
                    if (graph2.removeEdge(nodes2[source_idx], nodes2[destination_idx])) |_| {} else |_| break;
                },
                .repair_node => {
                    if (graph2.repairNode(nodes2[source_idx])) |_| {} else |_| break;
                },
                .remove_node => {
                    if (graph2.removeNode(nodes2[source_idx])) |_| {} else |_| break;
                },
            }
        }
    }

    try graph2.validate();
}

const OpKind = enum { add, remove, repair_node, remove_node };

const Op = struct {
    kind: OpKind,
    source: u8,
    destination: u8,
    rel: u16,
    flags: u16,
};

test "property_fuzz: random mutation sequence maintains graph invariants" {
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    const node_count: usize = 16;
    const op_count: usize = 500;
    var ops: [op_count]Op = undefined;

    var op_idx: usize = 0;
    while (op_idx < op_count) : (op_idx += 1) {
        ops[op_idx] = .{
            .kind = switch (random.int(u8) % 4) {
                0 => .add,
                1 => .remove,
                2 => .repair_node,
                else => .remove_node,
            },
            .source = @intCast(random.int(u8) % node_count),
            .destination = @intCast(random.int(u8) % node_count),
            .rel = random.int(u16),
            .flags = random.int(u16),
        };
    }

    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |idx| {
        nodes[idx] = try graph.addNode();
    }

    for (ops) |op| {
        if (op.source == op.destination) continue;

        switch (op.kind) {
            .add => {
                _ = graph.addEdge(nodes[op.source], nodes[op.destination], op.rel, @bitCast(op.flags)) catch {};
            },
            .remove => {
                _ = graph.removeEdge(nodes[op.source], nodes[op.destination]) catch {};
            },
            .repair_node => {
                _ = graph.repairNode(nodes[op.source]) catch azigmuth.RepairNodeSummary{};
            },
            .remove_node => {
                _ = graph.removeNode(nodes[op.source]) catch {};
            },
        }
    }

    try graph.validate();
}

test "property_fuzz: dense random graph with removals maintains consistency" {
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    const node_count: usize = 20;
    const initial_edges: usize = 200;
    const remove_ops: usize = 100;

    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var edge_idx: usize = 0;
    while (edge_idx < initial_edges) : (edge_idx += 1) {
        const source = random.int(u8) % node_count;
        const destination = random.int(u8) % node_count;
        if (source != destination) {
            _ = graph.addEdge(nodes[source], nodes[destination], 0, .{}) catch {};
        }
    }

    edge_idx = 0;
    while (edge_idx < remove_ops) : (edge_idx += 1) {
        const source = random.int(u8) % node_count;
        const destination = random.int(u8) % node_count;
        if (source != destination) {
            _ = graph.removeEdge(nodes[source], nodes[destination]) catch {};
        }
    }

    try graph.validate();

    var total_fwd: u64 = 0;
    var total_rev: u64 = 0;
    for (nodes) |node| {
        if (graph.hasNode(node)) {
            total_fwd += try snapshot_support.outDegree(graph, node, testing.allocator);
            total_rev += try snapshot_support.inDegree(graph, node, testing.allocator);
        }
    }

    try testing.expectEqual(total_fwd, total_rev);
    try testing.expectEqual(total_fwd, graph.edgeCount());
}

test "property_fuzz: removing all edges leaves clean graph" {
    var rng = std.Random.DefaultPrng.init(999);
    _ = rng.random();

    const node_count: usize = 10;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx) {
                _ = graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{}) catch {};
            }
        }
    }

    try graph.validate();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx) {
                _ = graph.removeEdge(nodes[source_idx], nodes[destination_idx]) catch {};
            }
        }
    }

    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    for (nodes) |node| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, node, testing.allocator));
        try testing.expectEqual(@as(usize, 0), try snapshot_support.inDegree(graph, node, testing.allocator));
    }
}

test "property_fuzz: alternate add and remove on same pair converges" {
    var rng = std.Random.DefaultPrng.init(7777);
    var random = rng.random();

    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const iterations: usize = 100;
    var model_expected: bool = false; // tracks what the model says should be present

    var iteration_idx: usize = 0;
    while (iteration_idx < iterations) : (iteration_idx += 1) {
        if (random.boolean()) {
            _ = graph.addEdge(source, destination, 0, .{}) catch {};
            model_expected = true;
        } else {
            const was_present = graph.removeEdge(source, destination) catch false;
            try testing.expectEqual(model_expected, was_present);
            model_expected = false;
        }
    }

    // Final state: if an edge remains, removeEdge returns true; if none, false.
    const final = graph.removeEdge(source, destination) catch false;
    try testing.expectEqual(model_expected, final);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, source, testing.allocator));
    try graph.validate();
}

test "property_fuzz: property that outDegree equals neighbors count" {
    var rng = std.Random.DefaultPrng.init(1111);
    const random = rng.random();

    const node_count: usize = 15;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx and random.boolean()) {
                _ = graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{}) catch {};
            }
        }
    }

    try graph.validate();

    for (nodes) |node| {
        if (!graph.hasNode(node)) continue;

        const degree = try snapshot_support.outDegree(graph, node, testing.allocator);
        var it = try snapshot_support.neighbors(graph, node, testing.allocator);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        it.deinit();
        try testing.expectEqual(degree, count);
    }
}

test "property_fuzz: property that inDegree equals inNeighbors count" {
    var rng = std.Random.DefaultPrng.init(2222);
    const random = rng.random();

    const node_count: usize = 15;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    for (0..node_count) |source_idx| {
        for (0..node_count) |destination_idx| {
            if (source_idx != destination_idx and random.boolean()) {
                _ = graph.addEdge(nodes[source_idx], nodes[destination_idx], 0, .{}) catch {};
            }
        }
    }

    try graph.validate();

    for (nodes) |node| {
        if (!graph.hasNode(node)) continue;

        const degree = try snapshot_support.inDegree(graph, node, testing.allocator);
        var it = try snapshot_support.inNeighbors(graph, node, testing.allocator);
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        it.deinit();
        try testing.expectEqual(degree, count);
    }
}

test "property_fuzz: addEdge removes self-edge correctness" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var attempt_idx: usize = 0;
    while (attempt_idx < 100) : (attempt_idx += 1) {
        _ = graph.addEdge(node, node, 0, .{}) catch {};
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try snapshot_support.outDegree(graph, node, testing.allocator));
    try testing.expectEqual(@as(usize, 1), try snapshot_support.inDegree(graph, node, testing.allocator));

    _ = graph.removeEdge(node, node) catch {};
    try graph.validate();
    try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, node, testing.allocator));
}

test "property_fuzz: random sequence with repair maintains validity" {
    var rng = std.Random.DefaultPrng.init(3333);
    const random = rng.random();

    const node_count: usize = 12;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var operation_idx: usize = 0;
    while (operation_idx < 300) : (operation_idx += 1) {
        const source = random.int(u8) % node_count;
        const destination = random.int(u8) % node_count;
        if (source != destination) {
            _ = graph.addEdge(nodes[source], nodes[destination], 0, .{}) catch {};
        }
    }

    operation_idx = 0;
    while (operation_idx < 50) : (operation_idx += 1) {
        const repair_node = random.int(u8) % node_count;
        _ = graph.repairNode(nodes[repair_node]) catch azigmuth.RepairNodeSummary{};
    }

    try graph.validate();
}

test "property_fuzz: removeNode followed by addNode reuses slots correctly" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const initial = try graph.addNode();
    try graph.addEdge(initial, initial, 0, .{});

    _ = try graph.removeNode(initial);
    try graph.validate();

    const new_node = try graph.addNode();
    try testing.expect(!graph.hasNode(initial));
    try testing.expect(graph.hasNode(new_node));

    try graph.addEdge(new_node, new_node, 0, .{});
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "property_fuzz: large sequential add then random remove maintains consistency" {
    var rng = std.Random.DefaultPrng.init(4444);
    var random = rng.random();

    var source = try azigmuth.Graph.init(testing.allocator);
    defer source.deinit();
    const source_node = try source.addNode();
    const target_count: usize = 100;
    var targets: [target_count]azigmuth.NodeId = undefined;
    for (0..target_count) |target_idx| targets[target_idx] = try source.addNode();

    for (0..target_count) |target_idx| {
        try source.addEdge(source_node, targets[target_idx], 0, .{});
    }

    try source.validate();

    var remove_attempt_idx: usize = 0;
    while (remove_attempt_idx < 50) : (remove_attempt_idx += 1) {
        const remove_idx = random.int(u8) % target_count;
        _ = source.removeEdge(source_node, targets[remove_idx]) catch {};
    }

    try source.validate();
    const degree = try snapshot_support.outDegree(source, source_node, testing.allocator);
    try testing.expect(degree >= 50 and degree <= 100);

    var it = try snapshot_support.neighbors(source, source_node, testing.allocator);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    it.deinit();
    try testing.expectEqual(degree, count);
}
