const std = @import("std");
const azigmuth = @import("azigmuth");

const testing = std.testing;

test "api repair: repairNode on single-block node succeeds" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    _ = try graph.repairNode(source);
    try graph.validate();
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "api repair: repairBudgeted returns repaired count" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired <= 1);
    try graph.validate();
}

test "api repair: removeNode summary reports repair debt after lazy removeNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});

    const summary = try graph.removeNode(target);
    try testing.expectEqual(@as(u64, 1), summary.removed_visible_edges);
    try testing.expectEqual(@as(u32, 1), summary.related_live_nodes_touched);
    try testing.expect(summary.left_repair_debt);
}

test "api repair: repairBudgeted drains flagged repair debt" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});

    const summary = try graph.removeNode(target);
    try testing.expect(summary.left_repair_debt);

    const repaired = try graph.repairBudgeted(summary.related_live_nodes_touched);
    try testing.expect(repaired > 0);
    try graph.validate();
}

test "api repair: debtStats exposes explicit repair debt" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});

    const summary = try graph.removeNode(target);
    try testing.expect(summary.left_repair_debt);

    const stats = try graph.debtStats();
    try testing.expect(stats.nodes_with_repair_fwd > 0 or stats.nodes_with_repair_rev > 0);
}

test "api repair: flushRepairs performs explicit repair pass" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});

    const summary = try graph.removeNode(target);
    try testing.expect(summary.left_repair_debt);

    const flush = try graph.flushRepairs();
    try testing.expect(flush.repaired_nodes > 0);
    try graph.validate();
}

test "api repair: repairBudgeted with max_nodes=0 returns 0" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(@as(usize, 0), try graph.repairBudgeted(0));
}

test "api repair: repairBudgeted retry after ConcurrentMutation succeeds" {
    const allocator = std.heap.page_allocator;
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    // removeNode leaves flagged forward-tombstone debt on every predecessor,
    // giving repairBudgeted a wide, reliable backlog for the race window.
    var predecessors: [256]azigmuth.NodeId = undefined;
    for (0..predecessors.len) |i| predecessors[i] = try graph.addNode();
    const hub = try graph.addNode();
    for (predecessors) |predecessor| try graph.addEdge(predecessor, hub, 0, .{});
    _ = try graph.removeNode(hub);

    var stop = std.atomic.Value(bool).init(false);
    var success_count = std.atomic.Value(u32).init(0);

    const Worker = struct {
        graph: *azigmuth.Graph,
        stop: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),

        fn run(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                const outcome = ctx.graph.repairBudgeted(10);
                if (outcome) |count| {
                    if (count > 0) _ = ctx.successes.fetchAdd(1, .monotonic);
                } else |err| {
                    if (err != error.ConcurrentMutation) return;
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    const worker = Worker{ .graph = graph, .stop = &stop, .successes = &success_count };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{worker});

    var attempt: usize = 0;
    while (attempt < 5000) : (attempt += 1) {
        if (graph.repairBudgeted(10)) |_| {
            break;
        } else |err| {
            if (err != error.ConcurrentMutation) return err;
        }
        std.atomic.spinLoopHint();
    }
    try testing.expect(attempt < 5000);

    stop.store(true, .release);
    worker_thread.join();

    // The worker may or may not win productive passes depending on timing;
    // the contract under test is that retrying after ConcurrentMutation
    // eventually succeeds (asserted above) and the graph stays valid.
    _ = success_count.load(.acquire);
    try graph.validate();
}

test "api repair: RepairRequired is resolved by explicit repairNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const hub = try graph.addNode(); // lowest destination: lands in slot 0 of block 0
    var fillers: [64]azigmuth.NodeId = undefined;
    for (0..fillers.len) |i| fillers[i] = try graph.addNode();

    try graph.addEdge(source, hub, 0, .{});
    for (fillers) |filler| try graph.addEdge(source, filler, 0, .{});

    // Push the hub's reverse side out of tiny mode so the removal takes the
    // strict single-removal path that enforces the hard occupancy bound.
    var extra_sources: [17]azigmuth.NodeId = undefined;
    for (0..extra_sources.len) |i| {
        extra_sources[i] = try graph.addNode();
        try graph.addEdge(extra_sources[i], hub, 0, .{});
    }

    // Drain the hub's block down to the occupancy floor (48 live).
    for (fillers[0..16]) |filler| {
        _ = try graph.removeEdge(source, filler);
    }

    // One more removal from that block would underflow the hard bound: the
    // engine refuses and asks for an explicit repair.
    try testing.expectError(error.RepairRequired, graph.removeEdge(source, hub));

    const summary = try graph.repairNode(source);
    try testing.expect(summary.repaired_fwd);

    // After the explicit repair the layout is compact and the removal works.
    try testing.expect(try graph.removeEdge(source, hub));
    try graph.validate();
}

test "api repair: repairNode on canonical node reports no work" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    const summary = try graph.repairNode(source);
    try testing.expect(!summary.repaired_fwd);
    try testing.expect(!summary.repaired_rev);
    try testing.expect(!summary.preventive_fwd);
    try testing.expect(!summary.preventive_rev);
    try graph.validate();
}
