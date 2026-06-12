const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

const ReaderTask = struct {
    graph: *const graph_mod.Graph,
    source: graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn readerLoop(task: *ReaderTask) void {
    while (!task.stop.load(.acquire)) {
        var iterator = task.graph.neighbors(task.source) catch continue;
        while (iterator.next() != null) {}
        iterator.deinit();
        _ = task.iterations.fetchAdd(1, .monotonic);
    }
}

const WriterTask = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn writerLoop(task: *WriterTask) void {
    const target_count = task.targets.len;
    var state: u64 = @intFromPtr(task);

    while (!task.stop.load(.acquire)) {
        const target = task.targets[@intCast(state % target_count)];
        state = state *% 6364136223846793005 +% 1442695040888963407;

        _ = task.graph.addEdge(task.source, target, 0, 0) catch continue;
        _ = task.graph.removeEdge(task.source, target) catch {};
        _ = task.iterations.fetchAdd(1, .monotonic);
    }
}

const ChurnTask = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn churnLoop(task: *ChurnTask) void {
    const target_count = task.targets.len;
    var state: u64 = @intFromPtr(task);
    while (!task.stop.load(.acquire)) {
        const target = task.targets[@intCast(state % target_count)];
        state = state *% 6364136223846793005 +% 1442695040888963407;

        _ = task.graph.addEdge(task.source, target, 0, 0) catch continue;
        _ = task.graph.removeEdge(task.source, target) catch {};
        task.graph.reclaimRetired();
        _ = task.iterations.fetchAdd(1, .monotonic);
    }
}

test "stress rcu: multiple readers and writers run concurrently without corrupting graph state" {
    var graph = try graph_mod.Graph.init(std.heap.page_allocator);

    const reader_source = try graph.addNode();
    var stable_targets: [10]graph_mod.NodeId = undefined;
    for (0..stable_targets.len) |target_idx| {
        stable_targets[target_idx] = try graph.addNode();
        try graph.addEdge(reader_source, stable_targets[target_idx], 0, 0);
    }

    const first_writer_source = try graph.addNode();
    const second_writer_source = try graph.addNode();
    var first_writer_targets: [8]graph_mod.NodeId = undefined;
    var second_writer_targets: [8]graph_mod.NodeId = undefined;
    for (0..8) |target_idx| {
        first_writer_targets[target_idx] = try graph.addNode();
        second_writer_targets[target_idx] = try graph.addNode();
    }

    var stop = std.atomic.Value(bool).init(false);

    var reader_tasks: [4]ReaderTask = undefined;
    var reader_threads: [4]std.Thread = undefined;
    for (0..reader_tasks.len) |reader_idx| {
        reader_tasks[reader_idx] = ReaderTask{
            .graph = &graph,
            .source = reader_source,
            .stop = &stop,
        };
        reader_threads[reader_idx] = try std.Thread.spawn(.{}, readerLoop, .{&reader_tasks[reader_idx]});
    }

    var first_writer = WriterTask{
        .graph = &graph,
        .source = first_writer_source,
        .targets = &first_writer_targets,
        .stop = &stop,
    };
    var second_writer = WriterTask{
        .graph = &graph,
        .source = second_writer_source,
        .targets = &second_writer_targets,
        .stop = &stop,
    };

    const first_thread = try std.Thread.spawn(.{}, writerLoop, .{&first_writer});
    const second_thread = try std.Thread.spawn(.{}, writerLoop, .{&second_writer});

    var spin_count: usize = 0;
    while (spin_count < 300000000) : (spin_count += 1) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);

    first_thread.join();
    second_thread.join();
    for (reader_threads) |reader_thread| {
        reader_thread.join();
    }

    try testing.expect(first_writer.iterations.load(.acquire) > 0);
    try testing.expect(second_writer.iterations.load(.acquire) > 0);
    for (reader_tasks) |reader_task| {
        try testing.expect(reader_task.iterations.load(.acquire) > 0);
    }

    var patience: usize = 10000;
    while (patience > 0 and graph.graph.active_readers.load(.acquire) > 0) {
        patience -= 1;
    }
    try testing.expect(patience > 0);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "stress rcu: flushRepairs drains explicit debt safely under concurrent churn" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    // Source node carries a permanent forward tombstone.
    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);
    _ = try graph.removeNode(target);
    try testing.expect((try graph.nodeAt(source)).publishedAdj().flags.needs_repair_fwd);

    // Churn node: continuously add/remove edges + reclaim, creating
    // block retirement traffic that exercises the reclamation path
    // while the repair thread traverses published blocks.
    const churn_source = try graph.addNode();
    var churn_targets: [8]graph_mod.NodeId = undefined;
    for (0..churn_targets.len) |i| {
        churn_targets[i] = try graph.addNode();
    }

    var stop = std.atomic.Value(bool).init(false);

    var churn = ChurnTask{
        .graph = &graph,
        .source = churn_source,
        .targets = &churn_targets,
        .stop = &stop,
    };
    const churn_thread = try std.Thread.spawn(.{}, churnLoop, .{&churn});

    // Main thread: keep the published repair flag intact while churn builds up
    // retirement traffic around the explicit repair pass.
    graph.graph.repair_scan_cursor_fwd = 0;
    graph.graph.repair_scan_cursor_rev = 0;

    // Let the churn thread build up traffic, then run flushRepairs
    // while blocks are being retired and reclaimed concurrently.
    var spin_warmup: usize = 0;
    while (spin_warmup < 5_000_000) : (spin_warmup += 1) {
        std.atomic.spinLoopHint();
    }

    const flush = try graph.flushRepairs();
    try testing.expect(flush.repaired_nodes > 0);

    stop.store(true, .release);
    churn_thread.join();

    try testing.expect(churn.iterations.load(.acquire) > 0);

    var patience: usize = 10000;
    while (patience > 0 and graph.graph.active_readers.load(.acquire) > 0) {
        patience -= 1;
    }
    try testing.expect(patience > 0);

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
