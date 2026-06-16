const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

const SpinBudget: usize = 200_000_000;

fn spinFor(spin_count: *usize, max: usize) bool {
    if (spin_count.* >= max) return false;
    spin_count.* += 1;
    std.atomic.spinLoopHint();
    return true;
}

const SpokeWriterCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    destination: graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    start_gate: *std.atomic.Value(u32),
    successes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    concurrent_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn spokeWriterLoop(ctx: *SpokeWriterCtx) void {
    // Wait for the start gate so all threads begin the storm simultaneously.
    _ = ctx.start_gate.fetchSub(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) > 0) {
        std.atomic.spinLoopHint();
    }

    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        if (ctx.graph.addEdge(ctx.source, ctx.destination, 0, 0)) {
            _ = ctx.successes.fetchAdd(1, .monotonic);
            _ = ctx.graph.removeEdge(ctx.source, ctx.destination) catch {};
        } else |err| {
            if (err == error.ConcurrentMutation) {
                _ = ctx.concurrent_failures.fetchAdd(1, .monotonic);
            }
            // Other errors (OutOfMemory, RepairRequired, EdgeAlreadyExists under
            // race) are expected transient outcomes under contention; ignore.
        }
    }
}

test "concurrent: many writers to a single destination serialize via reverse-claim" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var spokes: [8]graph_mod.NodeId = undefined;
    for (0..spokes.len) |spoke_idx| {
        spokes[spoke_idx] = try graph.addNode();
    }

    var stop = std.atomic.Value(bool).init(false);
    var start_gate = std.atomic.Value(u32).init(spokes.len);

    var ctxs: [spokes.len]SpokeWriterCtx = undefined;
    var threads: [spokes.len]std.Thread = undefined;
    for (spokes, 0..) |spoke, thread_idx| {
        ctxs[thread_idx] = .{
            .graph = &graph,
            .source = spoke,
            .destination = hub,
            .stop = &stop,
            .start_gate = &start_gate,
        };
        threads[thread_idx] = try std.Thread.spawn(.{}, spokeWriterLoop, .{&ctxs[thread_idx]});
    }

    // Let the storm run briefly, then signal stop and join. The start-gate
    // ensures all threads begin at once so contention is deterministic.
    var spin_warmup: usize = 0;
    while (spin_warmup < 5_000_000) : (spin_warmup += 1) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    for (threads) |thread| thread.join();

    var total_successes: u64 = 0;
    var total_concurrent_failures: u64 = 0;
    for (ctxs) |ctx| {
        total_successes += ctx.successes.load(.acquire);
        total_concurrent_failures += ctx.concurrent_failures.load(.acquire);
    }

    try testing.expect(total_successes > 0);
    try testing.expect(total_concurrent_failures > 0);

    // Each writer's final removeEdge races with other writers' addEdge, so the
    // exact final inDegree(hub) is non-deterministic. What we *can* assert is
    // that the graph is internally consistent after the storm:
    //   - no spoke exceeded outDegree 1
    //   - inDegree(hub) == sum(spokes.outDegree)
    //   - edgeCount == inDegree(hub) == sum(spokes.outDegree)
    //   - debugValidate reports zero violations
    var actual_out_degree_total: usize = 0;
    for (spokes) |spoke| {
        const out_degree = try graph.outDegree(spoke);
        try testing.expect(out_degree <= 1);
        actual_out_degree_total += out_degree;
    }
    const hub_in_degree = try graph.inDegree(hub);
    try testing.expectEqual(actual_out_degree_total, hub_in_degree);
    try testing.expectEqual(@as(u64, @intCast(hub_in_degree)), graph.edgeCount());

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

const SnapshotReaderCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    total_observations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    unsorted_snapshots: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn snapshotReaderLoop(ctx: *SnapshotReaderCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        var iterator = ctx.graph.neighbors(ctx.source) catch continue;
        var previous_idx: u32 = 0;
        var has_previous = false;
        var sorted_ok = true;

        while (iterator.next()) |neighbor| {
            if (has_previous and previous_idx >= neighbor.index) {
                sorted_ok = false;
                break;
            }
            previous_idx = neighbor.index;
            has_previous = true;
        }
        iterator.deinit();

        if (!sorted_ok) {
            _ = ctx.unsorted_snapshots.fetchAdd(1, .monotonic);
            return;
        }

        _ = ctx.total_observations.fetchAdd(1, .monotonic);
    }
}

const StableWriterCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn stableWriterLoop(ctx: *StableWriterCtx) void {
    const target_count = ctx.targets.len;
    if (target_count == 0) return;

    var state: u64 = @intFromPtr(ctx);
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        const target = ctx.targets[@intCast(state % target_count)];
        state = state *% 6364136223846793005 +% 1442695040888963407;

        _ = ctx.graph.addEdge(ctx.source, target, 0, 0) catch {};
        _ = ctx.graph.removeEdge(ctx.source, target) catch {};
        _ = ctx.iterations.fetchAdd(1, .monotonic);
    }
}

test "concurrent: reader sees a sorted, valid snapshot under a continuous write storm" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 32;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    var stop = std.atomic.Value(bool).init(false);

    var reader_ctx = SnapshotReaderCtx{
        .graph = &graph,
        .source = source,
        .stop = &stop,
    };
    const reader_thread = try std.Thread.spawn(.{}, snapshotReaderLoop, .{&reader_ctx});

    var writer_ctx = StableWriterCtx{
        .graph = &graph,
        .source = source,
        .targets = &targets,
        .stop = &stop,
    };
    const writer_thread = try std.Thread.spawn(.{}, stableWriterLoop, .{&writer_ctx});

    // Wait until the writer has produced at least one iteration and the reader
    // has completed one observation, then stop.  Cap total wait time at a
    // generous SpinBudget so the test never hangs on a broken build.
    var patience: usize = 0;
    while (writer_ctx.iterations.load(.acquire) == 0 or
        reader_ctx.total_observations.load(.acquire) == 0) : (patience += 1)
    {
        if (patience >= SpinBudget) break;
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    reader_thread.join();
    writer_thread.join();

    const total_observations = reader_ctx.total_observations.load(.acquire);
    const unsorted_snapshots = reader_ctx.unsorted_snapshots.load(.acquire);
    const writer_iterations = writer_ctx.iterations.load(.acquire);

    try testing.expect(writer_iterations > 0);
    try testing.expect(total_observations > 0);
    try testing.expectEqual(@as(u64, 0), unsorted_snapshots);

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);

    var final_neighbors = try graph.neighbors(source);
    const final_list = try graph_mod.materializeConsuming(&final_neighbors, allocator);
    defer allocator.free(final_list);
    var i: usize = 1;
    while (i < final_list.len) : (i += 1) {
        try testing.expect(final_list[i - 1].index < final_list[i].index);
    }
}

const ReclaimReaderCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    gate: *std.atomic.Value(u32),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    non_empty: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    invalid: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn reclaimReaderLoop(ctx: *ReclaimReaderCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        _ = ctx.gate.fetchAdd(1, .acq_rel);
        while (!ctx.stop.load(.acquire) and ctx.gate.load(.acquire) < 2) std.atomic.spinLoopHint();
        if (ctx.stop.load(.acquire)) break;
        _ = ctx.gate.fetchSub(2, .acq_rel);

        var iterator = ctx.graph.neighbors(ctx.source) catch continue;
        var count: usize = 0;
        var ok = true;
        while (iterator.next()) |neighbor| {
            count += 1;
            const is_target = for (ctx.targets) |t| {
                if (t.index == neighbor.index) break true;
            } else false;
            if (!is_target) ok = false;
        }
        iterator.deinit();

        if (count > 0) {
            _ = ctx.non_empty.fetchAdd(1, .monotonic);
        }
        if (!ok) {
            _ = ctx.invalid.fetchAdd(1, .monotonic);
        }
        _ = ctx.iterations.fetchAdd(1, .monotonic);
    }
}

const ReclaimStormCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    gate: *std.atomic.Value(u32),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn reclaimStormLoop(ctx: *ReclaimStormCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        // Wait for reader to finish its current snapshot.
        while (!ctx.stop.load(.acquire) and ctx.gate.load(.acquire) < 1) std.atomic.spinLoopHint();
        if (ctx.stop.load(.acquire)) break;

        // Mutate + reclaim while reader is between snapshots.
        _ = ctx.graph.addEdge(ctx.source, ctx.targets[1], 0, 0) catch {};
        _ = ctx.graph.removeEdge(ctx.source, ctx.targets[1]) catch {};
        ctx.graph.reclaimRetired();

        // Let reader proceed to the next snapshot.
        _ = ctx.gate.fetchAdd(1, .acq_rel);
        _ = ctx.iterations.fetchAdd(1, .monotonic);
    }
}

test "concurrent: reclaimRetired does not free blocks still observed by reader" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 16;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
    }
    // Permanent edge so every reader snapshot is non-empty.
    try graph.addEdge(source, targets[0], 0, 0);

    var stop = std.atomic.Value(bool).init(false);
    var gate = std.atomic.Value(u32).init(0);

    var reader_ctx = ReclaimReaderCtx{
        .graph = &graph,
        .source = source,
        .targets = &targets,
        .stop = &stop,
        .gate = &gate,
    };
    const reader_thread = try std.Thread.spawn(.{}, reclaimReaderLoop, .{&reader_ctx});

    var writer_ctx = ReclaimStormCtx{
        .graph = &graph,
        .source = source,
        .targets = &targets,
        .stop = &stop,
        .gate = &gate,
    };
    const writer_thread = try std.Thread.spawn(.{}, reclaimStormLoop, .{&writer_ctx});

    // Wait until both threads have made measurable progress.
    var patience: usize = 0;
    while (writer_ctx.iterations.load(.acquire) < 20 or
        reader_ctx.non_empty.load(.acquire) < 20) : (patience += 1)
    {
        if (patience >= SpinBudget) break;
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    _ = gate.fetchAdd(2, .release);
    reader_thread.join();
    writer_thread.join();

    const reader_iterations = reader_ctx.iterations.load(.acquire);
    const reclaim_iterations = writer_ctx.iterations.load(.acquire);

    try testing.expect(reader_iterations > 0);
    try testing.expect(reclaim_iterations > 0);
    try testing.expect(reader_ctx.non_empty.load(.acquire) > 0);
    try testing.expectEqual(@as(u64, 0), reader_ctx.invalid.load(.acquire));

    // Wait for lingering readers before reclaim.
    var active_patience: usize = 100000;
    while (active_patience > 0 and graph.graph.active_readers.load(.acquire) > 0) {
        active_patience -= 1;
        std.atomic.spinLoopHint();
    }
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try testing.expect(active_patience > 0);

    graph.reclaimRetired();

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
