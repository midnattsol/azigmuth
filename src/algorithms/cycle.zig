const std = @import("std");
const types = @import("../core/types.zig");
const common = @import("common.zig");

/// Returns true if the fixed captured graph view contains at least one
/// directed cycle.
pub fn hasCycleCaptured(view: *const common.CapturedGraphView, allocator: std.mem.Allocator) types.GraphError!bool {
    const node_count = view.nodeCount();
    if (node_count == 0) return false;

    var indegrees = try allocator.alloc(u32, node_count);
    defer allocator.free(indegrees);

    const zero_indegree = try allocator.alloc(u32, node_count);
    defer allocator.free(zero_indegree);

    var zero_count: usize = 0;

    for (0..node_count) |node_idx_usize| {
        if (!view.isLiveIndex(@intCast(node_idx_usize))) {
            indegrees[node_idx_usize] = 0;
            continue;
        }

        indegrees[node_idx_usize] = view.degree_rev[node_idx_usize];
        if (indegrees[node_idx_usize] == 0) {
            zero_indegree[zero_count] = @intCast(node_idx_usize);
            zero_count += 1;
        }
    }

    var processed_live: usize = 0;
    var head: usize = 0;
    while (head < zero_count) : (head += 1) {
        const current_idx = zero_indegree[head];
        processed_live += 1;

        var cursor = try view.neighborsCursor(.{ .index = current_idx }) orelse continue;
        while (cursor.next()) |neighbor| {
            const neighbor_idx: usize = neighbor.index;
            std.debug.assert(indegrees[neighbor_idx] > 0);
            indegrees[neighbor_idx] -= 1;
            if (indegrees[neighbor_idx] == 0) {
                zero_indegree[zero_count] = neighbor.index;
                zero_count += 1;
            }
        }
    }

    return processed_live != view.liveNodeCount();
}
