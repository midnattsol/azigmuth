const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const snapshot_view = @import("../../../query/snapshot/view.zig");
const shared = @import("shared.zig");
const prop_rows = @import("../prop_rows.zig");

pub fn debugValidateLive(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    var list: std.ArrayList(types.Violation) = .empty;
    errdefer list.deinit(allocator);

    var tracking = try shared.TrackingSets.init(graph, allocator);
    defer tracking.deinit(allocator);

    var totals = shared.VisibleTotals{};
    const node_count = graph.publishedNodeCount();
    for (0..node_count) |node_idx| {
        const node_id: u32 = @intCast(node_idx);
        const node = types.NodeId{ .index = node_id };
        const adjacency = node_access.publishedAdjAtConst(graph, node);
        const state = node_access.loadPublicationStateAtConst(graph, node);
        const node_totals = try shared.appendNodeViolations(graph, allocator, &list, &tracking, node_id, adjacency, node_access.publishedFwdDegreeFromStateAtConst(graph, node, state), node_access.publishedRevDegreeFromStateAtConst(graph, node, state));
        totals.fwd += node_totals.fwd;
        totals.rev += node_totals.rev;
        if (!adjacency.flags.removed) {
            try prop_rows.appendForwardPropRowViolations(graph, allocator, &list, node_id, adjacency);
        }
    }

    try prop_rows.appendGlobalPropRowUniquenessViolations(graph, allocator, &list);
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

    var totals = shared.VisibleTotals{};
    const node_count = view.nodeCount();
    for (0..node_count) |node_idx| {
        const node_id: u32 = @intCast(node_idx);
        const adjacency = view.adjacency(node_id);
        const node_totals = try shared.appendSnapshotNodeViolations(graph, allocator, &list, node_id, adjacency, view.degree_fwd[node_id], view.degree_rev[node_id]);
        totals.fwd += node_totals.fwd;
        totals.rev += node_totals.rev;
    }

    try shared.appendTotalViolations(graph, allocator, &list, totals, false);
    return list.toOwnedSlice(allocator);
}
