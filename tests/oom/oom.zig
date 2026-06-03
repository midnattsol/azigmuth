const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;

const testing = std.testing;

fn expectNoDebugViolations(graph: *const graph_mod.Graph) !void {
    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "oom: init reports OutOfMemory when the first node page cannot be allocated" {
    var buffer: [1]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);

    try testing.expectError(error.OutOfMemory, graph_mod.Graph.init(fixed_buffer.allocator()));
}

test "oom: addNode failure while adding a new page leaves node count unchanged" {
    var buffer: [24 * 1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);

    var graph = try graph_mod.Graph.init(fixed_buffer.allocator());
    defer graph.deinit();

    for (0..constants.NODES_PER_PAGE) |_| {
        _ = try graph.addNode();
    }
    try testing.expectEqual(@as(usize, constants.NODES_PER_PAGE), graph.nodeCount());

    try testing.expectError(error.OutOfMemory, graph.addNode());
    try testing.expectEqual(@as(usize, constants.NODES_PER_PAGE), graph.nodeCount());
}

test "oom: direct block allocation failure leaves counters unchanged" {
    var buffer: [24 * 1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);

    var graph = try graph_mod.Graph.init(fixed_buffer.allocator());
    defer graph.deinit();

    try testing.expectError(error.OutOfMemory, graph.allocBlockFwd());
    try testing.expectError(error.OutOfMemory, graph.allocBlockRev());
    try testing.expectEqual(@as(u32, 0), graph.graph.block_fwd_count);
    try testing.expectEqual(@as(u32, 0), graph.graph.block_rev_count);
    try testing.expectEqual(@as(usize, 0), 0);
    try testing.expectEqual(@as(usize, 0), 0);
}

test "oom: addEdge failure before forward block allocation does not publish an edge" {
    var buffer: [24 * 1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);

    var graph = try graph_mod.Graph.init(fixed_buffer.allocator());
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    try testing.expectError(error.OutOfMemory, graph.addEdge(source, destination, 0, 0));
    try testing.expectEqual(@as(u32, 0), graph.graph.block_fwd_count);
    try testing.expectEqual(@as(usize, 0), 0);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
    try graph.validate();
}

test "oom: addEdge failure while preparing reverse adjacency does not publish partial state" {
    var buffer: [56 * 1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);

    var graph = try graph_mod.Graph.init(fixed_buffer.allocator());
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    try testing.expectError(error.OutOfMemory, graph.addEdge(source, destination, 0, 0));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
    try graph.validate();
}

test "oom: removeEdge induced allocation failures do not publish or retire partial state" {
    for (0..8) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        const source = try graph.addNode();
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, 0);
        try expectNoDebugViolations(&graph);

        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;
        const result = graph.removeEdge(source, destination);

        if (result) |removed| {
            try testing.expect(removed);
            try testing.expectEqual(@as(u64, 0), graph.edgeCount());
            try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
            try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
            try graph.validate();
            try expectNoDebugViolations(&graph);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(@as(u64, 1), graph.edgeCount());
                try testing.expectEqual(@as(usize, 1), try graph.outDegree(source));
                try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
                try graph.validate();
                try expectNoDebugViolations(&graph);
            },
            else => return err,
        }
    }
}

test "oom: removeNode induced allocation failures do not publish partial state" {
    for (0..12) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        const removed = try graph.addNode();
        const destination = try graph.addNode();
        const other_source = try graph.addNode();
        try graph.addEdge(removed, destination, 0, 0);
        try graph.addEdge(other_source, destination, 0, 0);
        try expectNoDebugViolations(&graph);

        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;
        const result = graph.removeNode(removed);

        if (result) |_| {
            try testing.expectEqual(@as(u64, 1), graph.edgeCount());
            try testing.expect(!graph.hasNode(removed));
            try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
            try testing.expectEqual(@as(usize, 1), try graph.outDegree(other_source));
            try graph.validate();
            try expectNoDebugViolations(&graph);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expect(graph.hasNode(removed));
                try testing.expectEqual(@as(u64, 2), graph.edgeCount());
                try testing.expectEqual(@as(usize, 1), try graph.outDegree(removed));
                try testing.expectEqual(@as(usize, 2), try graph.inDegree(destination));
                try testing.expectEqual(@as(usize, 1), try graph.outDegree(other_source));
                try graph.validate();
                try expectNoDebugViolations(&graph);
            },
            else => return err,
        }
    }
}

test "oom: retire/reclaim cycle preserves graph validity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..5) |_| {
        const block = try graph.allocBlockFwd();
        try graph.retireBlockFwd(block);
    }

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    try graph.validate();
}
