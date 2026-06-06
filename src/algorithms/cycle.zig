const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");
const query = @import("../query.zig");

/// A frame in the iterative DFS stack used by `hasCycle`.
const StackEntry = struct {
    node: types.NodeId,
    iterator: query.NeighborIterator,
};

/// Returns true if the graph contains at least one directed cycle.
/// Uses an iterative DFS and materializes each frame's neighbors from a
/// single iterator snapshot.
///
/// Concurrent-safe, but not a global snapshot: detection runs over a valid
/// evolving view of the graph while mutations continue.
pub fn hasCycle(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) types.GraphError!bool {
    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return false;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer seen.deinit(allocator);
    var active = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer active.deinit(allocator);

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, node_count);
    defer {
        for (stack.items) |*entry| entry.iterator.deinit();
        stack.deinit(allocator);
    }

    for (0..node_count) |node_index| {
        if (seen.isSet(node_index)) continue;
        if (node_validity.isNodeRemovedIndex(graph, @intCast(node_index))) {
            seen.set(node_index);
            continue;
        }

        seen.set(node_index);
        active.set(node_index);

        const neighbors = try common.neighborIteratorOrNull(graph, .{ .index = @intCast(node_index) }) orelse continue;
        try stack.append(allocator, .{
            .node = .{ .index = @intCast(node_index) },
            .iterator = neighbors,
        });

        while (stack.items.len > 0) {
            const current = &stack.items[stack.items.len - 1];

            var found_unvisited = false;
            while (current.iterator.next()) |neighbor| {
                const neighbor_index: usize = @intCast(neighbor.index);

                // Revalidate liveness: a neighbor materialized earlier may
                // have been removed before this frame consumes it.
                if (!node_validity.isNodeLiveIndex(graph, @intCast(neighbor_index))) continue;

                try common.ensureBitCapacity(&seen, allocator, @intCast(neighbor_index));
                try common.ensureBitCapacity(&active, allocator, @intCast(neighbor_index));

                if (seen.isSet(neighbor_index) and active.isSet(neighbor_index)) return true;
                if (seen.isSet(neighbor_index)) continue;

                const next_neighbors = try common.neighborIteratorOrNull(graph, .{ .index = @intCast(neighbor_index) }) orelse continue;
                seen.set(neighbor_index);
                active.set(neighbor_index);
                try stack.append(allocator, .{ .node = .{ .index = @intCast(neighbor_index) }, .iterator = next_neighbors });
                found_unvisited = true;
                break;
            }

            if (!found_unvisited) {
                active.unset(current.node.index);
                current.iterator.deinit();
                _ = stack.pop();
            }
        }
    }

    return false;
}
