const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

const ReaderContext = struct {
    graph: *const graph_mod.Graph,
    source: graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn readerLoop(context: *ReaderContext) void {
    while (!context.stop.load(.acquire)) {
        var iterator = context.graph.neighbors(context.source) catch @panic("reader failed to create iterator");
        var count: usize = 0;
        while (iterator.next() != null) {
            count += 1;
        }
        iterator.deinit();
        _ = context.iterations.fetchAdd(1, .monotonic);
    }
}

fn waitForReaderIterations(first: *ReaderContext, second: *ReaderContext, min_iterations: u32) !void {
    var patience: usize = 1_000_000;
    while (patience > 0) : (patience -= 1) {
        if (first.iterations.load(.acquire) >= min_iterations and
            second.iterations.load(.acquire) >= min_iterations)
        {
            return;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return error.TestUnexpectedResult;
}

test "rcu: iterator keeps old snapshot while source adjacency mutates" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const first_destination = try graph.addNode();
    const second_destination = try graph.addNode();

    try graph.addEdge(source, first_destination, 0, 0);
    var old_iterator = try graph.neighbors(source);
    try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));

    try graph.addEdge(source, second_destination, 0, 0);
    try graph.validate();

    const old_neighbors = try old_iterator.materializeConsuming(testing.allocator);
    defer testing.allocator.free(old_neighbors);
    try testing.expectEqual(@as(usize, 1), old_neighbors.len);
    try testing.expectEqual(first_destination.index, old_neighbors[0].index);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    var new_iterator = try graph.neighbors(source);
    const new_neighbors = try new_iterator.materializeConsuming(testing.allocator);
    defer testing.allocator.free(new_neighbors);
    try testing.expectEqual(@as(usize, 2), new_neighbors.len);
    try testing.expectEqual(first_destination.index, new_neighbors[0].index);
    try testing.expectEqual(second_destination.index, new_neighbors[1].index);
}

test "rcu: readers release properly after edge removal" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    var first_reader = try graph.neighbors(source);
    var second_reader = try graph.neighbors(source);
    try testing.expectEqual(@as(u32, 2), graph.graph.active_readers.load(.acquire));

    try testing.expect(try graph.removeEdge(source, destination));
    graph.reclaimRetired();
    first_reader.deinit();
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    second_reader.deinit();
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "rcu: materialize releases reader guard" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    var iterator = try graph.neighbors(source);
    try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));
    const neighbors = try iterator.materializeConsuming(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "rcu: failed query does not enter reader critical section" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try testing.expectError(error.InvalidNode, graph.neighbors(.{ .index = 99 }));
    try testing.expectError(error.InvalidNode, graph.inNeighbors(.{ .index = 99 }));
    try testing.expectError(error.InvalidNode, graph.outDegree(.{ .index = 99 }));
    try testing.expectError(error.InvalidNode, graph.inDegree(.{ .index = 99 }));
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "rcu: reader threads can iterate while a writer publishes updates" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var stable_targets: [10]graph_mod.NodeId = undefined;
    for (0..stable_targets.len) |target_index| {
        stable_targets[target_index] = try graph.addNode();
        try graph.addEdge(source, stable_targets[target_index], 0, 0);
    }
    const toggled_target = try graph.addNode();

    var stop = std.atomic.Value(bool).init(false);
    var first_context = ReaderContext{ .graph = &graph, .source = source, .stop = &stop };
    var second_context = ReaderContext{ .graph = &graph, .source = source, .stop = &stop };

    var first_thread = try std.Thread.spawn(.{}, readerLoop, .{&first_context});
    var second_thread = try std.Thread.spawn(.{}, readerLoop, .{&second_context});
    try waitForReaderIterations(&first_context, &second_context, 1);

    for (0..30) |_| {
        try graph.addEdge(source, toggled_target, 0, 0);
        try graph.validate();
        try testing.expect(try graph.removeEdge(source, toggled_target));
        try graph.validate();
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    stop.store(true, .release);
    first_thread.join();
    second_thread.join();

    try testing.expect(first_context.iterations.load(.acquire) > 0);
    try testing.expect(second_context.iterations.load(.acquire) > 0);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try graph.validate();
}

test "rcu: reclaimRetired scans reader epoch slots even before active_readers increments" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
            // Simulate the critical window in readerEnter: the reader published its
    // epoch slot but has not yet incremented active_readers.
    graph.graph.reader_epochs[0].store(1, .release);
    graph.reclaimRetired();

            graph.graph.reader_epochs[0].store(0, .release);
    graph.bumpEpoch();
    graph.reclaimRetired();

        }
