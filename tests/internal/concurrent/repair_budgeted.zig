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
    for (0..30) |source_idx| {
        for (0..@min(source_idx, 4)) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(.{ .index = @intCast(source_idx) }, .{ .index = @intCast(destination_idx) }, 0, 0);
        }
    }
}

test "concurrent repair: two repairBudgeted callers in parallel do not crash or corrupt" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    for (0..30) |_| _ = try graph.addNode();

    // Create edges and repair debt so both repairers have work.
    for (0..30) |source_idx| {
        for (0..@min(source_idx, 4)) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(.{ .index = @intCast(source_idx) }, .{ .index = @intCast(destination_idx) }, 0, 0);
        }
    }

    // Mark many nodes for repair to create contention on the queue.
    for (0..30) |node_idx| {
        if (node_idx % 3 == 0) {
            var state = graph_mod.page_ops_mod.nodePublicationAtConst(&graph.graph, .{ .index = @intCast(node_idx) }).loadPublicationState();
            var flags = state.flags();
            flags.needs_repair_fwd = true;
            state = state.withFlags(flags);
            publish.storePublicationState(&graph, @intCast(node_idx), state);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer_a = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = graph_ptr.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    const repairer_b = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = graph_ptr.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    var wait_spins: usize = 0;
    while (wait_spins < 20_000_000) : (wait_spins += 1) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);

    repairer_a.join();
    repairer_b.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    for (violations) |violation| {
        switch (violation) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blocksegment_chain_cycle,
            .blocksegment_overlap,
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

    for (0..20) |source_idx| {
        for (0..@min(source_idx, 4)) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(.{ .index = @intCast(source_idx) }, .{ .index = @intCast(destination_idx) }, 0, 0);
        }
    }

    for (0..20) |node_idx| {
        if (node_idx % 5 == 0) {
            var state = graph_mod.page_ops_mod.nodePublicationAtConst(&graph.graph, .{ .index = @intCast(node_idx) }).loadPublicationState();
            var flags = state.flags();
            flags.needs_repair_fwd = true;
            state = state.withFlags(flags);
            publish.storePublicationState(&graph, @intCast(node_idx), state);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = graph_ptr.repairBudgeted(2) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    const mutator = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const source_idx: u32 = @intCast(spin % 20);
                const destination_idx: u32 = @intCast((spin + 1) % 20);
                if (source_idx != destination_idx) {
                    _ = graph_ptr.removeEdge(.{ .index = source_idx }, .{ .index = destination_idx }) catch {};
                }
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    for (violations) |violation| {
        switch (violation) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blocksegment_chain_cycle,
            .blocksegment_overlap,
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

    for (0..20) |source_idx| {
        for (0..@min(source_idx, 4)) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(.{ .index = @intCast(source_idx) }, .{ .index = @intCast(destination_idx) }, 0, 0);
        }
    }

    for (0..20) |node_idx| {
        if (node_idx % 5 == 0) {
            var state = graph_mod.page_ops_mod.nodePublicationAtConst(&graph.graph, .{ .index = @intCast(node_idx) }).loadPublicationState();
            var flags = state.flags();
            flags.needs_repair_fwd = true;
            state = state.withFlags(flags);
            publish.storePublicationState(&graph, @intCast(node_idx), state);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repairer = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = graph_ptr.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    const mutator = try std.Thread.spawn(.{}, struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const node_idx: u32 = @intCast(spin % 20);
                _ = graph_ptr.removeNode(.{ .index = node_idx }) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    for (violations) |violation| {
        switch (violation) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blocksegment_chain_cycle,
            .blocksegment_overlap,
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

    for (0..16) |source_idx| {
        for (0..@min(source_idx, 4)) |destination_idx| {
            if (source_idx != destination_idx) try graph.addEdge(.{ .index = @intCast(source_idx) }, .{ .index = @intCast(destination_idx) }, 0, 0);
        }
    }

    for (0..16) |node_idx| {
        if (node_idx % 4 == 0) {
            const node = try graph.nodeAt(.{ .index = @intCast(node_idx) });
            var flags = node.loadPublicationState().flags();
            flags.needs_repair_fwd = true;
            publish.setPublishedFlags(node, flags);
        }
    }

    var stop = std.atomic.Value(bool).init(false);

    const repair_fn = struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                _ = graph_ptr.repairBudgeted(1) catch {};
                std.atomic.spinLoopHint();
            }
        }
    }.segment;

    const mutator_fn = struct {
        fn segment(graph_ptr: *graph_mod.Graph, stop_ptr: *std.atomic.Value(bool)) void {
            var spin: usize = 0;
            while (!stop_ptr.load(.acquire) and spin < 200_000_000) : (spin += 1) {
                const node_count = graph_ptr.graph.publishedNodeCount();
                if (node_count < 2) continue;
                const source_idx: u32 = @intCast(spin % node_count);
                const destination_idx: u32 = @intCast((spin * 7 + 3) % node_count);
                if (source_idx == destination_idx) continue;

                switch (spin % 3) {
                    0 => _ = graph_ptr.addEdge(.{ .index = source_idx }, .{ .index = destination_idx }, 0, 0) catch {},
                    1 => _ = graph_ptr.removeEdge(.{ .index = source_idx }, .{ .index = destination_idx }) catch {},
                    2 => _ = graph_ptr.removeNode(.{ .index = destination_idx }) catch {},
                    else => unreachable,
                }
                std.atomic.spinLoopHint();
            }
        }
    }.segment;

    const repairer = try std.Thread.spawn(.{}, repair_fn, .{ &graph, &stop });
    const mutator = try std.Thread.spawn(.{}, mutator_fn, .{ &graph, &stop });

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) std.atomic.spinLoopHint();
    stop.store(true, .release);

    mutator.join();
    repairer.join();

    try drainRepairDebtUntilIdle(&graph);

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);

    for (violations) |violation| {
        switch (violation) {
            .block_double_owned,
            .block_orphaned_in_free_list,
            .blocksegment_chain_cycle,
            .blocksegment_overlap,
            .retired_block_reachable,
            .unreachable_forward_block,
            .unreachable_reverse_block,
            .forward_reverse_mismatch,
            => try testing.expect(false),
            else => {},
        }
    }
}
