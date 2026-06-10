const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

fn expectNoDebugViolations(graph: *const graph_mod.Graph) !void {
    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "oom: addEdge failure during group allocation does not publish partial state" {
    // Fill the forward block (64 edges) so the next addEdge must allocate
    // a new block and a group for non-contiguous block layout.
    for (0..12) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        const source = try graph.addNode();
        const destination = try graph.addNode();
        var targets: [64]graph_mod.NodeId = undefined;
        for (0..64) |i| {
            targets[i] = try graph.addNode();
        }

        for (0..64) |i| {
            try graph.addEdge(source, targets[i], 0, 0);
        }
        // Forward block is full (64/64); destination has 0 reverse edges.

        try expectNoDebugViolations(&graph);

        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;
        const result = graph.addEdge(source, destination, 0, 0);

        if (result) |_| {
            try testing.expectEqual(@as(u64, 65), graph.edgeCount());
            try testing.expectEqual(@as(usize, 65), try graph.outDegree(source));
            try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
            try graph.validate();
            try expectNoDebugViolations(&graph);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(@as(u64, 64), graph.edgeCount());
                try testing.expectEqual(@as(usize, 64), try graph.outDegree(source));
                try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
                try graph.validate();
                try expectNoDebugViolations(&graph);
            },
            else => return err,
        }
    }
}

test "oom: addEdge with full tail block fails gracefully under OOM at varying allocations" {
    // Same scenario as above but also fills reverse to cover both sides.
    for (0..16) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        const source = try graph.addNode();
        const hub = try graph.addNode();
        var targets: [64]graph_mod.NodeId = undefined;
        for (0..64) |i| {
            targets[i] = try graph.addNode();
            try graph.addEdge(source, targets[i], 0, 0);
        }
        // source forward block full.
        // Add edges to hub's reverse to fill one side.
        for (0..64) |_| {
            const s = try graph.addNode();
            try graph.addEdge(s, hub, 0, 0);
        }
        // hub reverse block full.

        try expectNoDebugViolations(&graph);

        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;
        const result = graph.addEdge(source, hub, 0, 0);

        if (result) |_| {
            try testing.expectEqual(@as(u64, 129), graph.edgeCount());
            try graph.validate();
            try expectNoDebugViolations(&graph);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(@as(u64, 128), graph.edgeCount());
                try graph.validate();
                try expectNoDebugViolations(&graph);
            },
            else => return err,
        }
    }
}
