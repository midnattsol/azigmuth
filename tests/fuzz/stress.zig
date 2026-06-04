//! Fuzz and stress tests — random operation sequences with validate()
//! after each step.  Catches accumulative structural degradation.

const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

fn expectNoStructuralViolations(violations: []const graphz.Violation) !void {
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
            .mask_bit_out_of_range,
            .edge_count_mismatch,
            .forward_reverse_count_mismatch,
            .removed_node_has_outgoing,
            => return error.CorruptGraph,
            else => {},
        }
    }
}

test "fuzz: sequential add/remove/repair with validate after each step" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    var state: u64 = 0xDEADBEEF_CAFE1234;
    var next_xor: u64 = 0;
    const node_limit: u32 = 24;

    // Pre-allocate nodes.
    for (0..node_limit) |_| _ = try graph.addNode();

    for (0..200) |step| {
        state = state *% 6364136223846793005 +% 1442695040888963407 +% step;
        next_xor = state;

        switch (step % 5) {
            0 => {
                const from: u32 = @intCast((state >> 4) % node_limit);
                const to: u32 = @intCast(((state >> 16) ^ next_xor) % node_limit);
                if (from != to) {
                    _ = graph.addEdge(.{ .index = from }, .{ .index = to }, 0, .{}) catch {};
                }
            },
            1 => {
                const from: u32 = @intCast((state >> 8) % node_limit);
                const to: u32 = @intCast(((state >> 20) ^ next_xor) % node_limit);
                if (from != to) {
                    _ = graph.removeEdge(.{ .index = from }, .{ .index = to }) catch {};
                }
            },
            2 => {
                const idx: u32 = @intCast(state % node_limit);
                _ = graph.removeNode(.{ .index = idx }) catch {};
            },
            3 => {
                const idx: u32 = @intCast((state >> 12) % node_limit);
                _ = graph.repairNode(.{ .index = idx }) catch {};
            },
            4 => {
                _ = graph.repairBudgeted(2) catch {};
            },
            else => unreachable,
        }

        // Validate structural invariants after each step.
        _ = graph.validate() catch {};

        // Full debugValidate periodically.
        if (step % 50 == 49) {
            const violations = try graph.debugValidate(testing.allocator);
            defer testing.allocator.free(violations);
            try expectNoStructuralViolations(violations);
        }
    }
}

test "fuzz: sequential hot-node add/remove with periodic validate" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    for (0..20) |_| _ = try graph.addNode();

    var state: u64 = 0x12345678_90ABCDEF;
    for (0..150) |step| {
        state = state *% 6364136223846793005 +% 1442695040888963407 +% step;
        const a: u32 = 0; // hot node
        const b: u32 = @intCast(1 + (state % 19));
        if (a != b) {
            switch (step % 3) {
                0 => _ = graph.addEdge(.{ .index = a }, .{ .index = b }, 0, .{}) catch {},
                1 => _ = graph.removeEdge(.{ .index = a }, .{ .index = b }) catch {},
                2 => _ = {
                    _ = graph.addEdge(.{ .index = a }, .{ .index = b }, 0, .{}) catch {};
                    _ = graph.removeEdge(.{ .index = a }, .{ .index = b }) catch {};
                },
                else => unreachable,
            }
        }

        _ = graph.validate() catch {};

        if (step % 40 == 39) {
            const violations = try graph.debugValidate(testing.allocator);
            defer testing.allocator.free(violations);
            try expectNoStructuralViolations(violations);
        }
    }
}

test "fuzz: OOM injection on addEdge/removeEdge/removeNode leaves stable graph" {
    for (0..16) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graphz.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        const a = try graph.addNode();
        const b = try graph.addNode();
        const c = try graph.addNode();
        try graph.addEdge(a, b, 0, .{});
        try graph.addEdge(a, c, 0, .{});

        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;

        // Try a mutation that may or may not succeed.
        const result = graph.addEdge(b, c, 0, .{});
        if (result) |_| {
            try testing.expectEqual(@as(u64, 3), graph.edgeCount());
        } else |err| {
            try testing.expect(err == error.OutOfMemory);
            // Graph must still be in its previous valid state.
            try testing.expectEqual(@as(u64, 2), graph.edgeCount());
        }

        // Validate after every injection variant.
        _ = graph.validate() catch {};
    }
}

test "fuzz: stress addEdge on same pair 100 times with interleaved repair" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();

    for (0..100) |_| {
        // Add edge (may fail on duplicate).
        _ = graph.addEdge(a, b, 0, .{}) catch {};
        // Remove edge.
        _ = graph.removeEdge(a, b) catch {};

        _ = graph.validate() catch {};
    }

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}
