const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

/// A frame in the iterative DFS stack used by `hasCycle`.
const StackEntry = struct {
    node: types.NodeId,
    cursor: common.NeighborsCursor,
};

/// Returns true if the graph contains at least one directed cycle.
/// Uses an iterative DFS over lightweight neighbor cursors backed by one
/// algorithm-wide read session.
///
/// Concurrent-safe, but not a global snapshot: detection runs over a valid
/// evolving view of the graph while mutations continue.
pub fn hasCycle(read: *const common.ReadSession, allocator: std.mem.Allocator) types.GraphError!bool {
    const node_count = read.nodeCount();
    if (node_count == 0) return false;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer seen.deinit(allocator);
    var active = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer active.deinit(allocator);

    var stack = try std.ArrayList(StackEntry).initCapacity(allocator, node_count);
    defer stack.deinit(allocator);

    for (0..node_count) |node_index| {
        if (seen.isSet(node_index)) continue;
        if (read.isNodeRemovedIndex(@intCast(node_index))) {
            seen.set(node_index);
            continue;
        }

        seen.set(node_index);
        active.set(node_index);

        const neighbors = try read.neighborsCursor(.{ .index = @intCast(node_index) }) orelse continue;
        try stack.append(allocator, .{
            .node = .{ .index = @intCast(node_index) },
            .cursor = neighbors,
        });

        while (stack.items.len > 0) {
            const current = &stack.items[stack.items.len - 1];

            var found_unvisited = false;
            while (current.cursor.next()) |neighbor| {
                const neighbor_index: usize = @intCast(neighbor.index);

                // Revalidate liveness: a neighbor materialized earlier may
                // have been removed before this frame consumes it.
                if (!read.isNodeLiveIndex(@intCast(neighbor_index))) continue;

                try common.ensureBitCapacity(&seen, allocator, @intCast(neighbor_index));
                try common.ensureBitCapacity(&active, allocator, @intCast(neighbor_index));

                if (seen.isSet(neighbor_index) and active.isSet(neighbor_index)) return true;
                if (seen.isSet(neighbor_index)) continue;

                const next_neighbors = try read.neighborsCursor(.{ .index = @intCast(neighbor_index) }) orelse continue;
                seen.set(neighbor_index);
                active.set(neighbor_index);
                try stack.append(allocator, .{ .node = .{ .index = @intCast(neighbor_index) }, .cursor = next_neighbors });
                found_unvisited = true;
                break;
            }

            if (!found_unvisited) {
                active.unset(current.node.index);
                _ = stack.pop();
            }
        }
    }

    return false;
}
