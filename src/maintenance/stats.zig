const graph_core = @import("../core/graph_core.zig");
const node_validity = @import("../core/node_validity.zig");
const page_ops = @import("../storage/page_ops.zig");
const rebuild = @import("repair/rebuild.zig");
const types = @import("../core/types.zig");
const debt = @import("repair/debt.zig");

pub fn debtStats(graph: *const graph_core.GraphCore) !types.DebtStats {
    const node_count = graph.publishedNodeCount();
    var stats = types.DebtStats{
        .live_nodes = 0,
        .removed_nodes = 0,
        .nodes_with_repair_fwd = 0,
        .nodes_with_repair_rev = 0,
        .queued_repair_fwd = debt.queuedRepairCount(@constCast(graph), .fwd),
        .queued_repair_rev = debt.queuedRepairCount(@constCast(graph), .rev),
        .grouped_fwd_nodes = 0,
        .grouped_rev_nodes = 0,
        .estimated_tombstone_fwd_nodes = 0,
    };

    for (0..node_count) |node_index_usize| {
        const node_index: u32 = @intCast(node_index_usize);
        const node_buffer = page_ops.nodeAtConst(graph, .{ .index = node_index });
        const meta = node_buffer.loadPublishedMeta();
        if (meta.removed) {
            stats.removed_nodes += 1;
            continue;
        }

        stats.live_nodes += 1;
        if (meta.needs_repair_fwd) stats.nodes_with_repair_fwd += 1;
        if (meta.needs_repair_rev) stats.nodes_with_repair_rev += 1;

        const adjacency = node_buffer.publishedAdjFromMeta(meta);
        if (adjacency.group_count_fwd > 0) stats.grouped_fwd_nodes += 1;
        if (adjacency.group_count_rev > 0) stats.grouped_rev_nodes += 1;

        if (adjacency.block_count_fwd > 0 and rebuild.hasAnyTombstone(
            graph,
            adjacency.first_block_fwd,
            adjacency.block_count_fwd,
            adjacency.group_count_fwd,
            adjacency.first_group_fwd,
            .fwd,
        )) {
            stats.estimated_tombstone_fwd_nodes += 1;
        }
    }

    return stats;
}
