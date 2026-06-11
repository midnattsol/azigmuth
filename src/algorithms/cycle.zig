const std = @import("std");
const context_mod = @import("context.zig");
const snapshot_iterators = @import("../query/snapshot/iterators.zig");
const snapshot_view = @import("../query/snapshot/view.zig");
const types = @import("../core/types.zig");

/// Returns true if the fixed captured graph view contains at least one
/// directed cycle. Honors `ctx.cancel_token` cooperatively: cancellation is
/// observed once per processed node and aborts with `error.Cancelled`.
pub fn hasCycleCaptured(view: *const snapshot_view.CapturedGraphView, ctx: context_mod.Context) types.GraphError!bool {
    const allocator = ctx.allocator;
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

    const Relax = struct {
        indegrees: []u32,
        zero_indegree: []u32,
        zero_count: *usize,

        fn onNeighbor(self: *@This(), neighbor_idx: u32) !void {
            std.debug.assert(self.indegrees[neighbor_idx] > 0);
            self.indegrees[neighbor_idx] -= 1;
            if (self.indegrees[neighbor_idx] == 0) {
                self.zero_indegree[self.zero_count.*] = neighbor_idx;
                self.zero_count.* += 1;
            }
        }
    };

    var processed_live: usize = 0;
    var head: usize = 0;
    while (head < zero_count) : (head += 1) {
        if (ctx.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
        const current_idx = zero_indegree[head];
        processed_live += 1;

        if (!view.isLiveIndex(current_idx)) continue;
        var relax = Relax{ .indegrees = indegrees, .zero_indegree = zero_indegree, .zero_count = &zero_count };
        try snapshot_iterators.forEachNeighborInView(view, current_idx, &relax, Relax.onNeighbor);
    }

    return processed_live != view.liveNodeCount();
}
