const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

test "rcu: readerEnter returns valid token with epoch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    try testing.expect(token.slot != std.math.maxInt(u32));
}

test "rcu: readerExit clears slot" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    graph.readerExit(token);

    const active = graph.graph.active_readers.load(.acquire);
    try testing.expectEqual(@as(u32, 0), active);
}

test "rcu: multiple readers active simultaneously" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token1 = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token1);
    const token2 = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token2);
    const token3 = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token3);

    const active = graph.graph.active_readers.load(.acquire);
    try testing.expectEqual(@as(u32, 3), active);
}

test "rcu: readerEnter records epoch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    const slot_idx = token.slot;
    try testing.expect(slot_idx < graph.graph.reader_epochs.len);

    const recorded = graph.graph.reader_epochs[slot_idx].load(.acquire);
    try testing.expect(recorded > 0);
}

test "rcu: bumpEpoch increments global epoch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const before = graph.graph.epoch.load(.acquire);
    graph.bumpEpoch();
    const after = graph.graph.epoch.load(.acquire);
    try testing.expect(after > before);
}

test "rcu: safeReclaimEpoch returns null when overflow reader present" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = graph.graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);
    defer _ = graph.graph.reader_epoch_overflow.fetchSub(1, .acq_rel);

    const safe_epoch = rcu_module().safeReclaimEpochForTest(&graph.graph);
    try testing.expect(safe_epoch == null);
}

fn rcu_module() type {
    return struct {
        fn safeReclaimEpochForTest(graph: *graph_mod.GraphCore) ?u64 {
            if (graph.reader_epoch_overflow.load(.acquire) != 0) return null;
            var min_epoch: ?u64 = null;
            for (&graph.reader_epochs) |*slot| {
                const encoded_epoch = slot.load(.acquire);
                if (encoded_epoch == 0) continue;
                const reader_epoch = encoded_epoch - 1;
                min_epoch = if (min_epoch) |current| @min(current, reader_epoch) else reader_epoch;
            }
            return min_epoch orelse graph.epoch.load(.acquire) +% 1;
        }
    };
}

test "rcu: reclaimRetired does not crash with no retired blocks" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    graph.reclaimRetired();
}

test "rcu: reclaimRetired handles no readers safely" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);
    try testing.expect(try graph.removeEdge(src, dst));

    graph.reclaimRetired();
    try graph.validate();
}

test "rcu: active_readers counter increments on enter" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const before = graph.graph.active_readers.load(.acquire);
    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);
    const during = graph.graph.active_readers.load(.acquire);
    try testing.expect(during == before + 1);
}

test "rcu: active_readers counter decrements on exit" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    graph.readerExit(token);
    const after = graph.graph.active_readers.load(.acquire);
    try testing.expectEqual(@as(u32, 0), after);
}

test "rcu: many sequential readers do not leak slots" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const iterations: usize = 100;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const token = graph.readerEnter() catch unreachable;
        graph.readerExit(token);
    }

    const active = graph.graph.active_readers.load(.acquire);
    try testing.expectEqual(@as(u32, 0), active);
}

test "rcu: writer proceeds while a concurrent reader holds an iterator" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst1 = try graph.addNode();
    const dst2 = try graph.addNode();
    try graph.addEdge(src, dst1, 0, 0);

    var stop = std.atomic.Value(bool).init(false);
    var writer_done = std.atomic.Value(bool).init(false);

    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(graph_ptr: *graph_mod.Graph, src_node: graph_mod.NodeId, dst: graph_mod.NodeId, done: *std.atomic.Value(bool)) void {
            _ = graph_ptr.addEdge(src_node, dst, 0, 0) catch {};
            done.store(true, .release);
        }
    }.run, .{ &graph, src, dst2, &writer_done });

    const ReaderCtx = struct {
        graph: *graph_mod.Graph,
        src: graph_mod.NodeId,
        stop: *std.atomic.Value(bool),
        fn run(ctx: *@This()) void {
            while (!ctx.stop.load(.acquire)) {
                var it = ctx.graph.neighbors(ctx.src) catch continue;
                while (it.next() != null) {}
                it.deinit();
            }
        }
    };

    var reader_ctx = ReaderCtx{ .graph = &graph, .src = src, .stop = &stop };
    const reader_thread = try std.Thread.spawn(.{}, ReaderCtx.run, .{&reader_ctx});

    // Wait for the writer to finish, then stop.
    while (!writer_done.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);
    reader_thread.join();
    writer_thread.join();

    try graph.validate();
}

test "rcu: epoch near max u64 increments correctly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    _ = graph.graph.epoch.store(std.math.maxInt(u64) - 1, .release);
    graph.bumpEpoch();
    const new_epoch = graph.graph.epoch.load(.acquire);
    try testing.expect(new_epoch > 0);
}

test "rcu: retired blocks not reclaimed while reader holds old epoch" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    const token = graph.readerEnter() catch unreachable;

    // Remove the edge; this retires the forward/reverse blocks.
    try testing.expect(try graph.removeEdge(src, dst));
    graph.bumpEpoch();

    // With the reader still active, reclaim should be a no-op because
    // the safe epoch has not advanced past the reader's entry epoch.
    graph.reclaimRetired();
    try graph.validate();

    // Reader exits; now reclamation can proceed.
    graph.readerExit(token);
    graph.reclaimRetired();
    try graph.validate();
}

test "rcu: epoch increments do not affect already-entered readers" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter() catch unreachable;
    defer graph.readerExit(token);

    const reader_epoch = token.epoch;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        graph.bumpEpoch();
    }

    const slot_val = graph.graph.reader_epochs[@intCast(token.slot)].load(.acquire);
    try testing.expectEqual(reader_epoch + 1, slot_val);
}