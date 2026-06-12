const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");

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
    graph: *const azigmuth.Graph,
    comptime node_count: usize,
    model: *const [node_count][node_count]bool,
    expected_edge_count: u64,
) !void {
    try graph.validate();
    try testing.expectEqual(expected_edge_count, graph.edgeCount());

    for (0..node_count) |source_idx| {
        var expected_out_degree: usize = 0;
        var expected_in_degree: usize = 0;
        for (0..node_count) |target_idx| {
            if (model[source_idx][target_idx]) expected_out_degree += 1;
            if (model[target_idx][source_idx]) expected_in_degree += 1;
        }
        try testing.expectEqual(expected_out_degree, try snapshot_support.outDegree(@constCast(graph), .{ .index = @intCast(source_idx) }, testing.allocator));
        try testing.expectEqual(expected_in_degree, try snapshot_support.inDegree(@constCast(graph), .{ .index = @intCast(source_idx) }, testing.allocator));

        var iterator = try snapshot_support.neighbors(@constCast(graph), .{ .index = @intCast(source_idx) }, testing.allocator);
        defer iterator.deinit();
        const neighbors = try iterator.materialize(testing.allocator);
        defer testing.allocator.free(neighbors);
        try testing.expectEqual(expected_out_degree, neighbors.len);
        for (neighbors) |neighbor| {
            try testing.expect(model[source_idx][neighbor.index]);
        }
    }
}

test "fuzz: random single-block mutations match a reference matrix" {
    const node_count = 24;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..node_count) |_| {
        _ = try graph.addNode();
    }

    var model = std.mem.zeroes([node_count][node_count]bool);
    var expected_edge_count: u64 = 0;
    var random = RandomStream{ .state = 0x1234_5678_9abc_def0 };

    for (0..350) |step| {
        const source_idx = random.bounded(node_count);
        const target_idx = random.bounded(node_count);
        const source = azigmuth.NodeId{ .index = source_idx };
        const target = azigmuth.NodeId{ .index = target_idx };

        if (random.bounded(2) == 0) {
            if (model[source_idx][target_idx]) {
                try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, target, 0, .{}));
            } else {
                try graph.addEdge(source, target, 0, .{});
                model[source_idx][target_idx] = true;
                expected_edge_count += 1;
            }
        } else {
            const removed = try graph.removeEdge(source, target);
            try testing.expectEqual(model[source_idx][target_idx], removed);
            if (removed) {
                model[source_idx][target_idx] = false;
                expected_edge_count -= 1;
            }
        }

        if (step % 25 == 0) {
            try graph.validate();
            try testing.expectEqual(expected_edge_count, graph.edgeCount());
        }
    }

    try expectGraphMatchesModel(graph, node_count, &model, expected_edge_count);

    // Full structural validation at the end.
    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "fuzz: random hub mutations preserve model state across multi-block adjacency" {
    const target_count = 100;
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [target_count]azigmuth.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
    }

    var model = std.mem.zeroes([target_count]bool);
    var expected_edge_count: u64 = 0;
    var random = RandomStream{ .state = 0xa5a5_1111_2222_3333 };

    for (0..450) |step| {
        const target_offset: usize = @intCast(random.bounded(target_count));
        const target = targets[target_offset];

        if (random.bounded(2) == 0) {
            if (model[target_offset]) {
                try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, target, 0, .{}));
            } else {
                try graph.addEdge(source, target, 0, .{});
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
    var snapshot = try graph.snapshot(.{ .allocator = testing.allocator });
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
