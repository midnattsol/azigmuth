const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;

const testing = std.testing;

const RandomStream = struct {
    state: u64,

    fn next(self: *RandomStream) u32 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @intCast(self.state >> 32);
    }

    fn bounded(self: *RandomStream, limit: u32) u32 {
        return self.next() % limit;
    }
};

fn expectGraphMatchesModel(
    graph: *const graph_mod.Graph,
    comptime node_count: usize,
    model: *const [node_count][node_count]bool,
    expected_edge_count: u64,
) !void {
    try graph.validate();
    try testing.expectEqual(expected_edge_count, graph.edgeCount());

    for (0..node_count) |source_index| {
        var expected_out_degree: usize = 0;
        var expected_in_degree: usize = 0;
        for (0..node_count) |target_index| {
            if (model[source_index][target_index]) expected_out_degree += 1;
            if (model[target_index][source_index]) expected_in_degree += 1;
        }
        try testing.expectEqual(expected_out_degree, try graph.outDegree(.{ .index = @intCast(source_index) }));
        try testing.expectEqual(expected_in_degree, try graph.inDegree(.{ .index = @intCast(source_index) }));

        var iterator = try graph.neighbors(.{ .index = @intCast(source_index) });
        const neighbors = try iterator.materialize(testing.allocator);
        defer testing.allocator.free(neighbors);
        try testing.expectEqual(expected_out_degree, neighbors.len);
        for (neighbors) |neighbor| {
            try testing.expect(model[source_index][neighbor.index]);
        }
    }
}

test "fuzz: random single-block mutations match a reference matrix" {
    const node_count = 24;
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..node_count) |_| {
        _ = try graph.addNode();
    }

    var model = std.mem.zeroes([node_count][node_count]bool);
    var expected_edge_count: u64 = 0;
    var random = RandomStream{ .state = 0x1234_5678_9abc_def0 };

    for (0..350) |step| {
        const source_index = random.bounded(node_count);
        const target_index = random.bounded(node_count);
        const source = graph_mod.NodeId{ .index = source_index };
        const target = graph_mod.NodeId{ .index = target_index };

        if (random.bounded(2) == 0) {
            if (model[source_index][target_index]) {
                try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, target, 0, 0));
            } else {
                try graph.addEdge(source, target, 0, 0);
                model[source_index][target_index] = true;
                expected_edge_count += 1;
            }
        } else {
            const removed = try graph.removeEdge(source, target);
            try testing.expectEqual(model[source_index][target_index], removed);
            if (removed) {
                model[source_index][target_index] = false;
                expected_edge_count -= 1;
            }
        }

        if (step % 25 == 0) {
            try graph.validate();
            try testing.expectEqual(expected_edge_count, graph.edgeCount());
        }
    }

    try expectGraphMatchesModel(&graph, node_count, &model, expected_edge_count);

    // Full structural validation at the end.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "fuzz: random hub mutations preserve model state across multi-block adjacency" {
    const target_count = 100;
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
    }

    var model = std.mem.zeroes([target_count]bool);
    var expected_edge_count: u64 = 0;
    var random = RandomStream{ .state = 0xa5a5_1111_2222_3333 };

    for (0..450) |step| {
        const target_offset: usize = @intCast(random.bounded(target_count));
        const target = targets[target_offset];

        if (random.bounded(2) == 0) {
            if (model[target_offset]) {
                try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, target, 0, 0));
            } else {
                try graph.addEdge(source, target, 0, 0);
                model[target_offset] = true;
                expected_edge_count += 1;
            }
        } else {
            const remove_result = graph.removeEdge(source, target);
            if (remove_result) |removed| {
                try testing.expectEqual(model[target_offset], removed);
                if (removed) {
                    model[target_offset] = false;
                    expected_edge_count -= 1;
                }
            } else |err| switch (err) {
                error.RepairRequired => try testing.expect(model[target_offset]),
                else => return err,
            }
        }

        if (step % 30 == 0) {
            try graph.validate();
            try testing.expectEqual(expected_edge_count, graph.edgeCount());
        }
    }

    // Full structural validation at the end.
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
