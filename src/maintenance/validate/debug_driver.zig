const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const snapshot_view = @import("../../query/snapshot_view.zig");
const shared = @import("debug_shared.zig");

pub fn debugValidateLive(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    var list: std.ArrayList(types.Violation) = .empty;
    errdefer list.deinit(allocator);

    var tracking = try shared.TrackingSets.init(graph, allocator);
    defer tracking.deinit(allocator);

    var totals = shared.VisibleTotals{};
    const node_count = graph.publishedNodeCount();
    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const node_buffer = @import("../../storage/page_ops.zig").nodeAtConst(graph, .{ .index = node_id });
        const adjacency = node_buffer.publishedAdj();
        const meta = node_buffer.loadPublishedMeta();
        const node_totals = try shared.appendNodeViolations(graph, allocator, &list, &tracking, node_id, adjacency, meta.degree_fwd, meta.degree_rev);
        totals.fwd += node_totals.fwd;
        totals.rev += node_totals.rev;
    }

    try shared.appendRepairDebtAndReachabilityViolations(graph, allocator, &list, &tracking);
    try shared.appendTotalViolations(graph, allocator, &list, totals, true);
    return list.toOwnedSlice(allocator);
}

pub fn debugValidateSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    allocator: std.mem.Allocator,
) ![]types.Violation {
    var list: std.ArrayList(types.Violation) = .empty;
    errdefer list.deinit(allocator);

    var tracking = try shared.TrackingSets.init(graph, allocator);
    defer tracking.deinit(allocator);

    var totals = shared.VisibleTotals{};
    const node_count = view.nodeCount();
    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = view.adjacency(node_id);
        const node_totals = try shared.appendNodeViolations(graph, allocator, &list, &tracking, node_id, adjacency, view.degree_fwd[node_id], view.degree_rev[node_id]);
        totals.fwd += node_totals.fwd;
        totals.rev += node_totals.rev;
    }

    try shared.appendRepairDebtAndReachabilityViolations(graph, allocator, &list, &tracking);
    try shared.appendTotalViolations(graph, allocator, &list, totals, true);
    return list.toOwnedSlice(allocator);
}
