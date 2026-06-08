const std = @import("std");
const graphz = @import("graphz");
const snapshot_support = @import("snapshot_support.zig");
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
        var i: usize = 1;
        while (i < candidate.len) {
            const reduced = candidate[0..i];
            var graph = try graphz.Graph.init(allocator);
            errdefer graph.deinit();

            var nodes: [16]graphz.NodeId = undefined;
            var j: usize = 0;
            while (j < initial_nodes and j < 16) : (j += 1) {
                nodes[j] = try graph.addNode();
            }

            var passed = true;
            for (reduced) |op| {
                const src_idx = op.src % @min(initial_nodes, 16);
                const dst_idx = op.dst % @min(initial_nodes, 16);
                if (src_idx == dst_idx) continue;
                if (graph.hasNode(nodes[src_idx]) and graph.hasNode(nodes[dst_idx])) {
                    switch (op.kind) {
                        .add => {
                            if (graph.addEdge(nodes[src_idx], nodes[dst_idx], op.rel, @bitCast(op.flags))) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .remove => {
                            if (graph.removeEdge(nodes[src_idx], nodes[dst_idx])) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .repair_node => {
                            if (graph.repairNode(nodes[src_idx])) |_| {} else |_| {
                                passed = false;
                                break;
                            }
                        },
                        .remove_node => {
                            if (graph.removeNode(nodes[src_idx])) |_| {} else |_| {
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
                i += 1;
            }
        }

        if (!removed_any) break;
    }

    var graph2 = try graphz.Graph.init(allocator);
    defer graph2.deinit();

    var nodes2: [16]graphz.NodeId = undefined;
    var k: usize = 0;
    while (k < initial_nodes and k < 16) : (k += 1) {
        nodes2[k] = try graph2.addNode();
    }

    for (ops) |op| {
        const src_idx = op.src % @min(initial_nodes, 16);
        const dst_idx = op.dst % @min(initial_nodes, 16);
        if (src_idx == dst_idx) continue;
        if (graph2.hasNode(nodes2[src_idx]) and graph2.hasNode(nodes2[dst_idx])) {
            switch (op.kind) {
                .add => {
                    if (graph2.addEdge(nodes2[src_idx], nodes2[dst_idx], op.rel, @bitCast(op.flags))) |_| {} else |_| break;
                },
                .remove => {
                    if (graph2.removeEdge(nodes2[src_idx], nodes2[dst_idx])) |_| {} else |_| break;
                },
                .repair_node => {
                    if (graph2.repairNode(nodes2[src_idx])) |_| {} else |_| break;
                },
                .remove_node => {
                    if (graph2.removeNode(nodes2[src_idx])) |_| {} else |_| break;
                },
            }
        }
    }

    try graph2.validate();
}

const OpKind = enum { add, remove, repair_node, remove_node };

const Op = struct {
    kind: OpKind,
    src: u8,
    dst: u8,
    rel: u16,
    flags: u16,
};

test "property_fuzz: random mutation sequence maintains graph invariants" {
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    const node_count: usize = 16;
    const op_count: usize = 500;
    var ops: [op_count]Op = undefined;

    var i: usize = 0;
    while (i < op_count) : (i += 1) {
        ops[i] = .{
            .kind = switch (random.int(u8) % 4) {
                0 => .add,
                1 => .remove,
                2 => .repair_node,
                else => .remove_node,
            },
            .src = @intCast(random.int(u8) % node_count),
            .dst = @intCast(random.int(u8) % node_count),
            .rel = random.int(u16),
            .flags = random.int(u16),
        };
    }

    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |idx| {
        nodes[idx] = try graph.addNode();
    }

    for (ops) |op| {
        if (op.src == op.dst) continue;

        switch (op.kind) {
            .add => {
                _ = graph.addEdge(nodes[op.src], nodes[op.dst], op.rel, @bitCast(op.flags)) catch {};
            },
            .remove => {
                _ = graph.removeEdge(nodes[op.src], nodes[op.dst]) catch {};
            },
            .repair_node => {
                _ = graph.repairNode(nodes[op.src]) catch {};
            },
            .remove_node => {
                _ = graph.removeNode(nodes[op.src]) catch {};
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

    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var i: usize = 0;
    while (i < initial_edges) : (i += 1) {
        const src = random.int(u8) % node_count;
        const dst = random.int(u8) % node_count;
        if (src != dst) {
            _ = graph.addEdge(nodes[src], nodes[dst], 0, .{}) catch {};
        }
    }

    i = 0;
    while (i < remove_ops) : (i += 1) {
        const src = random.int(u8) % node_count;
        const dst = random.int(u8) % node_count;
        if (src != dst) {
            _ = graph.removeEdge(nodes[src], nodes[dst]) catch {};
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) {
                _ = graph.addEdge(nodes[i], nodes[j], 0, .{}) catch {};
            }
        }
    }

    try graph.validate();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j) {
                _ = graph.removeEdge(nodes[i], nodes[j]) catch {};
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

    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    const iterations: usize = 100;
    var model_expected: bool = false; // tracks what the model says should be present

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j and random.boolean()) {
                _ = graph.addEdge(nodes[i], nodes[j], 0, .{}) catch {};
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    for (0..node_count) |i| {
        for (0..node_count) |j| {
            if (i != j and random.boolean()) {
                _ = graph.addEdge(nodes[i], nodes[j], 0, .{}) catch {};
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [node_count]graphz.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const src = random.int(u8) % node_count;
        const dst = random.int(u8) % node_count;
        if (src != dst) {
            _ = graph.addEdge(nodes[src], nodes[dst], 0, .{}) catch {};
        }
    }

    i = 0;
    while (i < 50) : (i += 1) {
        const repair_node = random.int(u8) % node_count;
        _ = graph.repairNode(nodes[repair_node]) catch {};
    }

    try graph.validate();
}

test "property_fuzz: removeNode followed by addNode reuses slots correctly" {
    var graph = try graphz.Graph.init(testing.allocator);
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

    var source = try graphz.Graph.init(testing.allocator);
    defer source.deinit();
    const source_node = try source.addNode();
    const target_count: usize = 100;
    var targets: [target_count]graphz.NodeId = undefined;
    for (0..target_count) |i| targets[i] = try source.addNode();

    for (0..target_count) |i| {
        try source.addEdge(source_node, targets[i], 0, .{});
    }

    try source.validate();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
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
