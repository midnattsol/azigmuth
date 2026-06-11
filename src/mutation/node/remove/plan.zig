const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const types = @import("../../../core/types.zig");
const common = @import("../../common.zig");
const node_validity = @import("../../../core/node_validity.zig");
const remove_types = @import("types.zig");

fn markRelatedNode(
    graph: *graph_core.GraphCore,
    related_nodes: *std.ArrayList(remove_types.RelatedNode),
    related_node_index: *std.AutoHashMap(u32, usize),
    node_index: u32,
    fwd_degree_delta: u22,
    rev_degree_delta: u22,
) !void {
    if (related_node_index.get(node_index)) |entry_idx| {
        const entry = &related_nodes.items[entry_idx];
        if (rev_degree_delta > 0) try entry.claims.ensureRev();
        entry.fwd_degree_delta += fwd_degree_delta;
        entry.rev_degree_delta += rev_degree_delta;
        return;
    }

    const claims = try common.tryClaimNodeSides(graph, node_index, false, rev_degree_delta > 0);
    try related_nodes.append(graph.allocator, .{
        .node_index = node_index,
        .node_meta = page_ops.nodeMetaAt(graph, .{ .index = node_index }),
        .claims = claims,
        .fwd_degree_delta = fwd_degree_delta,
        .rev_degree_delta = rev_degree_delta,
    });
    try related_node_index.put(node_index, related_nodes.items.len - 1);
}

/// Collects live neighbor nodes that need degree or repair-flag updates.
/// Returns claimed node-side state for the later publish step.
pub fn collectRelatedNodeUpdates(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    scan: *const remove_types.RemovalScan,
) !remove_types.RelatedUpdates {
    var related = remove_types.RelatedUpdates{
        .nodes = try std.ArrayList(remove_types.RelatedNode).initCapacity(graph.allocator, scan.forward_destinations.items.len + scan.visible_incoming),
        .index = std.AutoHashMap(u32, usize).init(graph.allocator),
    };
    errdefer related.deinit(graph.allocator);

    for (scan.forward_destinations.items) |destination_idx| {
        if (destination_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, destination_idx)) continue;
        try markRelatedNode(graph, &related.nodes, &related.index, destination_idx, 0, 1);
    }
    for (scan.reverse_sources.items) |source_idx| {
        if (source_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, source_idx)) continue;
        try markRelatedNode(graph, &related.nodes, &related.index, source_idx, 1, 0);
    }

    return related;
}
