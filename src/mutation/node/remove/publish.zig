const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const common = @import("../../common.zig");
const remove_types = @import("types.zig");

/// Builds a removed-node adjacency by clearing both published sides and flags.
pub fn buildRemovedAdjEmpty(source_adj: types.NodeAdj) types.NodeAdj {
    var removed_adj = source_adj;
    removed_adj.first_block_fwd = 0;
    removed_adj.block_count_fwd = 0;
    removed_adj.group_count_fwd = 0;
    removed_adj.first_group_fwd = 0;
    removed_adj.first_block_rev = 0;
    removed_adj.block_count_rev = 0;
    removed_adj.group_count_rev = 0;
    removed_adj.first_group_rev = 0;
    removed_adj.flags.removed = true;
    removed_adj.flags.needs_repair_fwd = false;
    removed_adj.flags.needs_repair_rev = false;
    return removed_adj;
}

/// Publishes degree and repair-flag deltas to related live nodes.
/// Returns counts of predecessor and destination nodes that were updated.
pub fn publishRelatedNodeUpdates(graph: *graph_core.GraphCore, related_nodes: []const remove_types.RelatedNode) remove_types.RemoveCounts {
    var counts = remove_types.RemoveCounts{};
    for (related_nodes) |related| {
        if (related.fwd_degree_delta > 0) counts.predecessors += 1;
        if (related.rev_degree_delta > 0) counts.destinations += 1;
        if (related.fwd_degree_delta == 0 and related.rev_degree_delta == 0) continue;

        const meta = related.node_meta.loadPublishedMeta();
        if (meta.removed) continue;
        counts.applied_edge_removals += @as(u64, related.fwd_degree_delta) + @as(u64, related.rev_degree_delta);
        const node_id = types.NodeId{ .index = related.node_index };
        const node_published = page_ops.ensureNodePublishedAt(graph, node_id) catch @panic("failed to ensure published page");
        if (related.fwd_degree_delta > 0 and related.rev_degree_delta > 0) {
            _ = common.publishMetaBothDeltaNoFlip(related.node_meta, node_published, .{
                .needs_repair_fwd = true,
                .needs_repair_rev = true,
                .removed = false,
            }, -@as(i23, @intCast(related.fwd_degree_delta)), -@as(i23, @intCast(related.rev_degree_delta)));
            continue;
        }

        if (related.fwd_degree_delta > 0) {
            _ = common.publishMetaFwdDeltaNoFlip(related.node_meta, node_published, true, -@as(i23, @intCast(related.fwd_degree_delta)));
        }
        if (related.rev_degree_delta > 0) {
            _ = common.publishMetaRevDeltaNoFlip(related.node_meta, node_published, true, -@as(i23, @intCast(related.rev_degree_delta)));
        }
    }
    return counts;
}

/// Retires both forward and reverse storage that previously belonged to a removed node.
pub fn retireRemovedNodeStorage(graph: *graph_core.GraphCore, source_adj: types.NodeAdj) !void {
    try common.retireSide(graph, source_adj, .fwd);
    try common.retireSide(graph, source_adj, .rev);
}
