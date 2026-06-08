const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const common = @import("../common.zig");
const node_validity = @import("../../core/node_validity.zig");
const remove_types = @import("remove_types.zig");

/// Forward-degree decrements on predecessors are published via CAS on
/// `published_meta`, so claiming `fwd_claim` on the predecessor is unnecessary
/// for that path. Only `rev_claim` is needed for any later explicit reverse-side
/// cleanup work.
fn markRelatedNode(
    graph: *graph_core.GraphCore,
    related_nodes: *std.ArrayList(remove_types.RelatedNode),
    related_node_index: *std.AutoHashMap(u32, usize),
    node_index: u32,
    need_rev_claim: bool,
    fwd_degree_delta: u22,
    rev_degree_delta: u22,
) !void {
    if (related_node_index.get(node_index)) |entry_idx| {
        const entry = &related_nodes.items[entry_idx];
        if (need_rev_claim) try entry.claims.ensureRev();
        entry.fwd_degree_delta += fwd_degree_delta;
        entry.rev_degree_delta += rev_degree_delta;
        return;
    }

    const node_buffer = page_ops.nodeAt(graph, .{ .index = node_index });
    const claims = try common.tryClaimNodeSides(node_buffer, false, need_rev_claim);
    try related_nodes.append(graph.allocator, .{
        .node_index = node_index,
        .node_buffer = node_buffer,
        .claims = claims,
        .fwd_degree_delta = fwd_degree_delta,
        .rev_degree_delta = rev_degree_delta,
    });
    try related_node_index.put(node_index, related_nodes.items.len - 1);
}

/// Collects live neighbor nodes that need degree or repair-flag updates.
/// Returns claimed node-side state for the later publish phase.
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
        try markRelatedNode(graph, &related.nodes, &related.index, destination_idx, true, 0, 1);
    }
    for (scan.reverse_sources.items) |source_idx| {
        if (source_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, source_idx)) continue;
        try markRelatedNode(graph, &related.nodes, &related.index, source_idx, true, 1, 0);
    }

    return related;
}
