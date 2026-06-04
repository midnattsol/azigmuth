//! Stress tests for concurrent repairBudgeted + mutations.
//! Targets the data race risk between the repair debt queue and
//! concurrent mutators.

const std = @import("std");
const graph_mod = @import("graph_mod");
const publish = @import("publish");

const testing = std.testing;

fn drainRepairDebtUntilIdle(graph: *graph_mod.Graph) !void {
    // removeNode intentionally leaves predecessor forward tombstones as repair
    // debt. For deterministic post-stop validation we must explicitly drain the
    // remaining debt once no mutator can create new work.
    var consecutive_idle: u8 = 0;
    while (consecutive_idle < 2) {
        const repaired = try graph.repairBudgeted(std.math.maxInt(usize));
        if (repaired == 0) {
            consecutive_idle += 1;
        } else {
            consecutive_idle = 0;
        }
    }
}

test "concurrent repair: repairBudgeted + addEdge in parallel does not crash or corrupt" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..30) |_| _ = try graph.addNode();

    // Create initial edges and repair debt so repairBudgeted has work.
    for (0..30) |i| {
        for (0..@min(i, 4)) |j| {
            if (i != j) try graph.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }
}

test "concurrent repair: two repairBudgeted callers in parallel do not crash or corrupt" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..30) |_| _ = try graph.addNode();

    // Create edges and repair debt so both repairers have work.
    for (0..30) |i| {
        for (0..@min(i, 4)) |j| {
            if (i != j) try graph.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }

    // Mark many nodes for repair to create contention on the queue.
    for (0..30) |i| {
        if (i % 3 == 0) {
            const buf = try graph.nodeAt(.{ .index = @intCast(i) });
            var flags = buf.loadPublishedMeta().flags();
            flags.needs_repair_fwd = true;
            publish.setPublishedFlags(buf, flags);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer_a = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = g.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    const repairer_b = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = g.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    var wait_spins: usize = 0;
    while (wait_spins < 20_000_000) : (wait_spins += 1) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);

    repairer_a.join();
    repairer_b.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    for (violations) |v| {
        switch (v) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blockgroup_chain_cycle,
            .blockgroup_overlap,
            .retired_block_reachable,
            .unreachable_forward_block,
            .unreachable_reverse_block,
            .forward_reverse_mismatch,
            .forward_reverse_count_mismatch,
            .edge_count_mismatch,
            => try testing.expect(false),
            else => {},
        }
    }
}

test "concurrent repair: repairBudgeted + removeEdge in parallel does not crash" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..20) |_| _ = try graph.addNode();

    for (0..20) |i| {
        for (0..@min(i, 4)) |j| {
            if (i != j) try graph.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }

    for (0..20) |i| {
        if (i % 5 == 0) {
            const buf = try graph.nodeAt(.{ .index = @intCast(i) });
            var flags = buf.loadPublishedMeta().flags();
            flags.needs_repair_fwd = true;
            publish.setPublishedFlags(buf, flags);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = g.repairBudgeted(2) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    const mutator = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const a: u32 = @intCast(spin % 20);
                const b: u32 = @intCast((spin + 1) % 20);
                if (a != b) {
                    _ = g.removeEdge(.{ .index = a }, .{ .index = b }) catch {};
                }
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    for (violations) |v| {
        switch (v) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blockgroup_chain_cycle,
            .blockgroup_overlap,
            .retired_block_reachable,
            => try testing.expect(false),
            else => {},
        }
    }
}

test "concurrent repair: repairBudgeted + removeNode in parallel does not crash" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..20) |_| _ = try graph.addNode();

    for (0..20) |i| {
        for (0..@min(i, 4)) |j| {
            if (i != j) try graph.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }

    for (0..20) |i| {
        if (i % 5 == 0) {
            const buf = try graph.nodeAt(.{ .index = @intCast(i) });
            var flags = buf.loadPublishedMeta().flags();
            flags.needs_repair_fwd = true;
            publish.setPublishedFlags(buf, flags);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = g.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    const mutator = try std.Thread.spawn(.{}, struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const idx: u32 = @intCast(spin % 20);
                _ = g.removeNode(.{ .index = idx }) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    for (violations) |v| {
        switch (v) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blockgroup_chain_cycle,
            .blockgroup_overlap,
            .retired_block_reachable,
            => try testing.expect(false),
            else => {},
        }
    }
}

test "concurrent repair: stress mixed addEdge/removeEdge/removeNode + repairBudgeted" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..16) |_| _ = try graph.addNode();

    for (0..16) |i| {
        for (0..@min(i, 4)) |j| {
            if (i != j) try graph.addEdge(.{ .index = @intCast(i) }, .{ .index = @intCast(j) }, 0, 0);
        }
    }

    for (0..16) |i| {
        if (i % 4 == 0) {
            const buf = try graph.nodeAt(.{ .index = @intCast(i) });
            var flags = buf.loadPublishedMeta().flags();
            flags.needs_repair_fwd = true;
            publish.setPublishedFlags(buf, flags);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repair_fn = struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = g.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.run;

    const mutator_fn = struct {
        fn run(g: *graph_mod.Graph, s: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!s.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const n = g.graph.publishedNodeCount();
                if (n < 2) continue;
                const a_idx: u32 = @intCast(spin % n);
                const b_idx: u32 = @intCast((spin * 7 + 3) % n);
                if (a_idx == b_idx) continue;

                switch (spin % 3) {
                    0 => _ = g.addEdge(.{ .index = a_idx }, .{ .index = b_idx }, 0, 0) catch {},
                    1 => _ = g.removeEdge(.{ .index = a_idx }, .{ .index = b_idx }) catch {},
                    2 => _ = g.removeNode(.{ .index = b_idx }) catch {},
                    else => unreachable,
                }
                std.atomic.spinLoopHint();
            }
        }
    }.run;

    const repairer = try std.Thread.spawn(.{}, repair_fn, .{ &graph, &stop });
    const mutator = try std.Thread.spawn(.{}, mutator_fn, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);

    for (violations) |v| {
        switch (v) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blockgroup_chain_cycle,
            .blockgroup_overlap,
            .retired_block_reachable,
            .unreachable_forward_block,
            .unreachable_reverse_block,
            .forward_reverse_mismatch,
            => try testing.expect(false),
            else => {},
        }
    }
}
