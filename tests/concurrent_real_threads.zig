const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
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
    for (0..spokes.len) |spoke_index| {
        spokes[spoke_index] = try graph.addNode();
    }

    var stop = std.atomic.Value(bool).init(false);
    var start_gate = std.atomic.Value(u32).init(spokes.len);

    var contexts: [spokes.len]SpokeWriterCtx = undefined;
    var threads: [spokes.len]std.Thread = undefined;
    for (spokes, 0..) |spoke, thread_index| {
        contexts[thread_index] = .{
            .graph = &graph,
            .source = spoke,
            .destination = hub,
            .stop = &stop,
            .start_gate = &start_gate,
        };
        threads[thread_index] = try std.Thread.spawn(.{}, spokeWriterLoop, .{&contexts[thread_index]});
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
    for (contexts) |ctx| {
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

    const violations = try graph.debugValidate(allocator);
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
        var previous_index: u32 = 0;
        var has_previous = false;
        var sorted_ok = true;

        while (iterator.next()) |neighbor| {
            if (has_previous and previous_index >= neighbor.index) {
                sorted_ok = false;
                break;
            }
            previous_index = neighbor.index;
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
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], 0, 0);
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

    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);

    var final_neighbors = try graph.neighbors(source);
    const final_list = try final_neighbors.materialize(allocator);
    defer allocator.free(final_list);
    var i: usize = 1;
    while (i < final_list.len) : (i += 1) {
        try testing.expect(final_list[i - 1].index < final_list[i].index);
    }
}

const ReclaimReaderCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn reclaimReaderLoop(ctx: *ReclaimReaderCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        var iterator = ctx.graph.neighbors(ctx.source) catch continue;
        var local_max: u32 = 0;
        while (iterator.next()) |neighbor| {
            if (neighbor.index > local_max) local_max = neighbor.index;
        }
        iterator.deinit();

        const prev_max = ctx.max_seen.load(.acquire);
        if (local_max > prev_max) {
            ctx.max_seen.store(local_max, .release);
        }
        _ = ctx.iterations.fetchAdd(1, .monotonic);
    }
}

const ReclaimStormCtx = struct {
    graph: *graph_mod.Graph,
    source: graph_mod.NodeId,
    targets: []const graph_mod.NodeId,
    stop: *std.atomic.Value(bool),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn reclaimStormLoop(ctx: *ReclaimStormCtx) void {
    const target_count = ctx.targets.len;
    if (target_count == 0) return;

    var state: u64 = @intFromPtr(ctx);
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        const target = ctx.targets[@intCast(state % target_count)];
        state = state *% 6364136223846793005 +% 1442695040888963407;

        _ = ctx.graph.addEdge(ctx.source, target, 0, 0) catch {};
        _ = ctx.graph.removeEdge(ctx.source, target) catch {};
        ctx.graph.reclaimRetired();
        _ = ctx.iterations.fetchAdd(1, .monotonic);
    }
}

test "concurrent: reclaimRetired racing with active readers does not free observed blocks" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 64;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
    }

    var stop = std.atomic.Value(bool).init(false);

    var reader_ctx = ReclaimReaderCtx{
        .graph = &graph,
        .source = source,
        .stop = &stop,
    };
    const reader_thread = try std.Thread.spawn(.{}, reclaimReaderLoop, .{&reader_ctx});

    var writer_ctx = ReclaimStormCtx{
        .graph = &graph,
        .source = source,
        .targets = &targets,
        .stop = &stop,
    };
    const writer_thread = try std.Thread.spawn(.{}, reclaimStormLoop, .{&writer_ctx});

    // Wait until both threads have made progress, then stop.
    var patience: usize = 0;
    while (writer_ctx.iterations.load(.acquire) == 0 or
        reader_ctx.iterations.load(.acquire) == 0) : (patience += 1)
    {
        if (patience >= SpinBudget) break;
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    reader_thread.join();
    writer_thread.join();

    const reader_iterations = reader_ctx.iterations.load(.acquire);
    const reclaim_iterations = writer_ctx.iterations.load(.acquire);

    try testing.expect(reader_iterations > 0);
    try testing.expect(reclaim_iterations > 0);
    try testing.expect(reader_ctx.max_seen.load(.acquire) > 0);

    // Wait for any lingering readers to exit before checking final state.
    var active_patience: usize = 100000;
    while (active_patience > 0 and graph.graph.active_readers.load(.acquire) > 0) {
        active_patience -= 1;
        std.atomic.spinLoopHint();
    }
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try testing.expect(active_patience > 0);

    var target_index_by_id = std.AutoHashMap(u32, usize).init(allocator);
    defer target_index_by_id.deinit();
    for (targets, 0..) |target, position| {
        try target_index_by_id.put(target.index, position);
    }

    var final_neighbors = try graph.neighbors(source);
    defer final_neighbors.deinit();

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, target_count);
    defer seen.deinit(allocator);
    while (final_neighbors.next()) |neighbor| {
        const position = target_index_by_id.get(neighbor.index) orelse {
            // A neighbor index not in the target set means reclaimRetired freed
            // a block that was still observable — the reader saw a stale/dangling
            // index from a freed edge block.
            try testing.expect(false);
            unreachable;
        };
        try testing.expect(!seen.isSet(position));
        seen.set(position);
    }

    graph.reclaimRetired();

    const violations = try graph.debugValidate(allocator);
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
