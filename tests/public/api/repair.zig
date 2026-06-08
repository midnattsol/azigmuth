const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

test "api repair: repairNode on single-block node succeeds" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    try graph.repairNode(source);
    try graph.validate();
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "api repair: repairBudgeted returns repaired count" {
    var graph = try graphz.Graph.init(testing.allocator);
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
    var graph = try graphz.Graph.init(testing.allocator);
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
    var graph = try graphz.Graph.init(testing.allocator);
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
    var graph = try graphz.Graph.init(testing.allocator);
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
    var graph = try graphz.Graph.init(testing.allocator);
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
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(@as(usize, 0), try graph.repairBudgeted(0));
}

test "api repair: repairBudgeted returns ConcurrentMutation when another repairer is active" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [130]graphz.NodeId = undefined;
    for (0..130) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, .{});
    }
    var removed: usize = 0;
    for (targets[0..]) |target| {
        if (removed >= 90) break;
        if (graph.removeEdge(source, target)) |did_remove| {
            if (did_remove) removed += 1;
        } else |_| return;
    }

    var start_gate = std.atomic.Value(u32).init(2);
    var results = [_]?graphz.GraphError!usize{ null, null };

    const Ctx = struct {
        graph: *graphz.Graph,
        start_gate: *std.atomic.Value(u32),
        result: *?graphz.GraphError!usize,

        fn run(ctx: @This()) void {
            _ = ctx.start_gate.fetchSub(1, .acq_rel);
            while (ctx.start_gate.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }

            var attempts: usize = 0;
            while (attempts < 200) : (attempts += 1) {
                const outcome = ctx.graph.repairBudgeted(10);
                ctx.result.* = outcome;
                if (outcome) |_| return else |err| {
                    if (err == error.ConcurrentMutation) return;
                }
                std.atomic.spinLoopHint();
            }
            ctx.result.* = null;
        }
    };

    const ctx_one = Ctx{ .graph = graph, .start_gate = &start_gate, .result = &results[0] };
    const ctx_two = Ctx{ .graph = graph, .start_gate = &start_gate, .result = &results[1] };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{ctx_one});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{ctx_two});
    t1.join();
    t2.join();

    const inner_one = results[0] orelse return error.TestExpectedEqual;
    const inner_two = results[1] orelse return error.TestExpectedEqual;

    const one_ok = if (inner_one) |_| true else |_| false;
    const two_ok = if (inner_two) |_| true else |_| false;
    try testing.expect(one_ok != two_ok);
    if (!one_ok) _ = inner_one catch |err| try testing.expectEqual(error.ConcurrentMutation, err);
    if (!two_ok) _ = inner_two catch |err| try testing.expectEqual(error.ConcurrentMutation, err);

    try graph.validate();
}

test "api repair: repairBudgeted retry after ConcurrentMutation succeeds" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [130]graphz.NodeId = undefined;
    for (0..130) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, .{});
    }
    var removed: usize = 0;
    for (targets[0..]) |target| {
        if (removed >= 90) break;
        if (graph.removeEdge(source, target)) |did_remove| {
            if (did_remove) removed += 1;
        } else |_| return;
    }

    var stop = std.atomic.Value(bool).init(false);
    var success_count = std.atomic.Value(u32).init(0);

    const Worker = struct {
        graph: *graphz.Graph,
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

    try testing.expect(success_count.load(.acquire) > 0);
    try graph.validate();
}
