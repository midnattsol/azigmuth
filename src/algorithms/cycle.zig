const std = @import("std");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const query = @import("../query.zig");

/// A frame in the iterative DFS stack used by `hasCycle`.
const StackEntry = struct {
    node: types.NodeId,
    neighbors: []const types.NodeId,
    next_neighbor: usize,
};

/// Returns true if the graph contains at least one directed cycle.
pub fn hasCycle(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) types.GraphError!bool {
    if (graph.node_count == 0) return false;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, graph.node_count);
    defer seen.deinit(allocator);
    var active = try std.DynamicBitSetUnmanaged.initEmpty(allocator, graph.node_count);
    defer active.deinit(allocator);

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, graph.node_count);
    defer {
        for (stack.items) |entry| allocator.free(entry.neighbors);
        stack.deinit(allocator);
    }

    for (0..graph.node_count) |node_index| {
        if (seen.isSet(node_index)) continue;

        seen.set(node_index);
        active.set(node_index);

        var iter = try query.neighbors(graph, .{ .index = @intCast(node_index) });
        const neighbors = try iter.materialize(allocator);
        try stack.append(allocator, .{
            .node = .{ .index = @intCast(node_index) },
            .neighbors = neighbors,
            .next_neighbor = 0,
        });

        while (stack.items.len > 0) {
            const current = &stack.items[stack.items.len - 1];

            var found_unvisited = false;
            while (current.next_neighbor < current.neighbors.len) {
                const neighbor_index: usize = @intCast(current.neighbors[current.next_neighbor].index);
                current.next_neighbor += 1;

                if (seen.isSet(neighbor_index) and active.isSet(neighbor_index)) return true;
                if (seen.isSet(neighbor_index)) continue;

                seen.set(neighbor_index);
                active.set(neighbor_index);

                var next_iter = try query.neighbors(graph, .{ .index = @intCast(neighbor_index) });
                const next_neighbors = try next_iter.materialize(allocator);
                try stack.append(allocator, .{
                    .node = .{ .index = @intCast(neighbor_index) },
                    .neighbors = next_neighbors,
                    .next_neighbor = 0,
                });
                found_unvisited = true;
                break;
            }

            if (!found_unvisited) {
                active.unset(current.node.index);
                const completed = stack.pop().?;
                allocator.free(completed.neighbors);
            }
        }
    }

    return false;
}
