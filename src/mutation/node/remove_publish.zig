const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const common = @import("../common.zig");
const remove_types = @import("remove_types.zig");

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

pub fn publishRelatedNodeUpdates(related_nodes: []const remove_types.RelatedNode) remove_types.RemoveCounts {
    var counts = remove_types.RemoveCounts{};
    for (related_nodes) |related| {
        if (related.fwd_degree_delta > 0) counts.predecessors += 1;
        if (related.rev_degree_delta > 0) counts.destinations += 1;
        if (related.fwd_degree_delta == 0 and related.rev_degree_delta == 0) continue;

        const meta = related.node_buffer.loadPublishedMeta();
        if (meta.removed) continue;
        if (related.fwd_degree_delta > 0 and related.rev_degree_delta > 0) {
            _ = common.publishMetaBothDeltaUpdated(related.node_buffer, meta, .{
                .needs_repair_fwd = true,
                .needs_repair_rev = true,
                .removed = false,
            }, related.fwd_degree_delta, related.rev_degree_delta);
            continue;
        }

        if (related.fwd_degree_delta > 0) {
            _ = common.publishMetaFwdDeltaUpdated(related.node_buffer, meta, true, related.fwd_degree_delta);
        }
        if (related.rev_degree_delta > 0) {
            _ = common.publishMetaRevDeltaUpdated(related.node_buffer, meta, true, related.rev_degree_delta);
        }
    }
    return counts;
}

pub fn retireRemovedNodeStorage(graph: *graph_core.GraphCore, source_adj: types.NodeAdj) !void {
    try common.retireSide(graph, source_adj, .fwd);
    try common.retireSide(graph, source_adj, .rev);
}
