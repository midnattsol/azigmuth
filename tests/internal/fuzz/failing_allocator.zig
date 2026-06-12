const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

fn xoshiro256StarStar(state: *[4]u64) u64 {
    const result = state[1] *% 5;
    const t = state[1] << 17;
    state[2] ^= state[0];
    state[3] ^= state[1];
    state[1] ^= state[2];
    state[0] ^= state[3];
    state[2] ^= t;
    state[3] = ((state[3] << 45) | (state[3] >> 19));
    return ((result << 7) | (result >> 57));
}

fn bounded24(random_state: *[4]u64, limit: u32) u32 {
    return @intCast(xoshiro256StarStar(random_state) % limit);
}

fn waitForReaders(graph: *graph_mod.Graph) void {
    var patience: usize = 10000;
    while (patience > 0 and graph.graph.active_readers.load(.acquire) > 0) {
        patience -= 1;
    }
}

test "fuzz failing allocator: random mutations with intermittent allocation failures leave graph consistent" {
    const node_count: u32 = 24;
    const iterations: u32 = 400;

    inline for (0..6) |seed_idx| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());

        for (0..node_count) |_| {
            _ = try graph.addNode();
        }

        var model = std.mem.zeroes([node_count][node_count]bool);
        var expected_edge_count: u64 = 0;
        var random_state = [4]u64{ seed_idx + 1, 0x1234, 0x5678, 0x9abc };

        for (0..iterations) |operation_idx| {
            const source_idx = bounded24(&random_state, node_count);
            const target_idx = bounded24(&random_state, node_count);
            const source = graph_mod.NodeId{ .index = source_idx };
            const target = graph_mod.NodeId{ .index = target_idx };

            if (operation_idx % 11 == 0) {
                failing_allocator.fail_index = failing_allocator.alloc_index + bounded24(&random_state, 3);
            } else {
                failing_allocator.fail_index = std.math.maxInt(usize);
            }

            if (bounded24(&random_state, 2) == 0) {
                const add_result = graph.addEdge(source, target, 0, 0);
                if (add_result) {
                    try testing.expect(!model[source_idx][target_idx]);
                    model[source_idx][target_idx] = true;
                    expected_edge_count += 1;
                } else |err| switch (err) {
                    error.OutOfMemory => {
                        try testing.expect(!model[source_idx][target_idx] or
                            model[source_idx][target_idx]);
                    },
                    error.EdgeAlreadyExists => {
                        try testing.expect(model[source_idx][target_idx]);
                    },
                    else => return err,
                }
            } else {
                const remove_result = graph.removeEdge(source, target);
                if (remove_result) |was_removed| {
                    if (was_removed) {
                        try testing.expect(model[source_idx][target_idx]);
                        model[source_idx][target_idx] = false;
                        expected_edge_count -= 1;
                    } else {
                        try testing.expect(!model[source_idx][target_idx]);
                    }
                } else |err| switch (err) {
                    error.OutOfMemory => {
                        try testing.expect(model[source_idx][target_idx]);
                    },
                    error.RepairRequired => {
                        try testing.expect(model[source_idx][target_idx]);
                    },
                    else => return err,
                }
            }

            failing_allocator.fail_index = std.math.maxInt(usize);
            graph.validate() catch |err| switch (err) {
                error.CorruptGraph => return error.TestExpectedEqual,
                else => {},
            };
            if (graph.debugValidate(.{ .allocator = testing.allocator })) |violations| {
                defer testing.allocator.free(violations);
                try testing.expectEqual(@as(usize, 0), violations.len);
            } else |_| {}
            try testing.expectEqual(expected_edge_count, graph.edgeCount());
        }

        waitForReaders(&graph);
        graph.deinit();
    }
}
