const graph_core = @import("../core/graph_core.zig");
const node_access = @import("../core/node_access.zig");
const node_validity = @import("../core/node_validity.zig");
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
        .segmented_fwd_nodes = 0,
        .segmented_rev_nodes = 0,
        .estimated_tombstone_fwd_nodes = 0,
    };

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        const node = types.NodeId{ .index = node_idx };
        const state = node_access.loadPublicationStateAtConst(graph, node);
        if (state.removed) {
            stats.removed_nodes += 1;
            continue;
        }

        stats.live_nodes += 1;
        if (state.needs_repair_fwd) stats.nodes_with_repair_fwd += 1;
        if (state.needs_repair_rev) stats.nodes_with_repair_rev += 1;

        const adjacency = node_access.publishedAdjFromStateAtConst(graph, node, state);
        if (adjacency.segment_count_fwd > 0) stats.segmented_fwd_nodes += 1;
        if (adjacency.segment_count_rev > 0) stats.segmented_rev_nodes += 1;

        if (adjacency.block_count_fwd > 0 and rebuild.hasAnyTombstone(
            graph,
            adjacency.first_block_fwd,
            adjacency.block_count_fwd,
            adjacency.segment_count_fwd,
            adjacency.first_segment_fwd,
            .fwd,
        )) {
            stats.estimated_tombstone_fwd_nodes += 1;
        }
    }

    return stats;
}
