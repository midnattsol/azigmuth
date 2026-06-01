const std = @import("std");
const graph = @import("../graph.zig");
const utils = @import("../utils.zig");

/// A frame in the iterative DFS stack, tracking the node being explored
/// and which neighbor we should examine next.
const StackEntry = struct {
    node: graph.NodeId,
    neighbors: []const graph.NodeId,
    next_neighbor: usize,
};

/// Detects whether a directed graph contains at least one cycle.
///
/// Uses iterative DFS with two bitsets to track 3 states per node:
///
///   seen | active |  meaning
///   ─────┼────────┼────────────────
///     0  |    X   |  unvisited
///     1  |    1   |  active: on the exploration path
///     1  |    0   |  completed: fully processed
///
/// A cycle exists when we encounter a neighbor that is both `seen` and `active`
/// (i.e. a back-edge to an ancestor still on the stack).
pub fn hasCycle(g: anytype, allocator: std.mem.Allocator) !bool {
    comptime utils.requireNeighborsAndNodeCount(@TypeOf(g));

    const node_count = g.nodeCount();
    if (node_count == 0) return false;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer seen.deinit(allocator);
    var active = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer active.deinit(allocator);

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, node_count);
    defer {
        for (stack.items) |entry| allocator.free(entry.neighbors);
        stack.deinit(allocator);
    }

    for (0..node_count) |i| {
        if (seen.isSet(i)) continue;

        seen.set(i);
        active.set(i);
        // Materialize neighbors once per node visited.
        var iter = try g.neighbors(.{ .index = @intCast(i) });
        const neighbors = try iter.materialize(allocator);
        try stack.append(allocator, .{ .node = .{ .index = @intCast(i) }, .neighbors = neighbors, .next_neighbor = 0 });

        while (stack.items.len > 0) {
            const current = &stack.items[stack.items.len - 1];

            var found_unvisited = false;
            while (current.next_neighbor < current.neighbors.len) {
                const idx: usize = @intCast(current.neighbors[current.next_neighbor].index);
                current.next_neighbor += 1;

                // Back-edge to a node still on the path → cycle.
                if (seen.isSet(idx) and active.isSet(idx)) return true;
                // Already fully explored → skip.
                if (seen.isSet(idx)) continue;

                // First time seeing this node → push onto exploration path.
                seen.set(idx);
                active.set(idx);
                var next_iter = try g.neighbors(.{ .index = @intCast(idx) });
                const next_neighbors = try next_iter.materialize(allocator);
                try stack.append(allocator, .{ .node = .{ .index = @intCast(idx) }, .neighbors = next_neighbors, .next_neighbor = 0 });
                found_unvisited = true;
                break;
            }

            // All neighbors processed → node is complete.
            if (!found_unvisited) {
                active.unset(current.node.index);
                const completed = stack.pop().?;
                allocator.free(completed.neighbors);
            }
        }
    }

    return false;
}

// ==================== Tests ====================

test "empty graph has no cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 0, &.{});
    defer g.deinit();
    try std.testing.expectEqual(false, try hasCycle(g, std.testing.allocator));
}

test "single node without edges has no cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 1, &.{});
    defer g.deinit();
    try std.testing.expectEqual(false, try hasCycle(g, std.testing.allocator));
}

test "single node with self-loop has cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 1, &.{
        .{ 0, 0 },
    });
    defer g.deinit();
    try std.testing.expectEqual(true, try hasCycle(g, std.testing.allocator));
}

test "two nodes no cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 2, &.{
        .{ 0, 1 },
    });
    defer g.deinit();
    try std.testing.expectEqual(false, try hasCycle(g, std.testing.allocator));
}

test "two nodes with cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 2, &.{
        .{ 0, 1 }, .{ 1, 0 },
    });
    defer g.deinit();
    try std.testing.expectEqual(true, try hasCycle(g, std.testing.allocator));
}

test "three nodes triangle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 3, &.{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 },
    });
    defer g.deinit();
    try std.testing.expectEqual(true, try hasCycle(g, std.testing.allocator));
}

test "disconnected graph, one component has cycle" {
    var g = try utils.buildTestGraph(std.testing.allocator, 4, &.{
        .{ 0, 1 }, .{ 2, 3 }, .{ 3, 2 },
    });
    defer g.deinit();
    try std.testing.expectEqual(true, try hasCycle(g, std.testing.allocator));
}

test "disconnected graph, no cycles" {
    var g = try utils.buildTestGraph(std.testing.allocator, 4, &.{
        .{ 0, 1 }, .{ 2, 3 },
    });
    defer g.deinit();
    try std.testing.expectEqual(false, try hasCycle(g, std.testing.allocator));
}
