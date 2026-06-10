const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const side_adj = @import("../../../adjacency/side_ops.zig");
const layout_debt = @import("../../layout_debt.zig");
const rebuild_mod = @import("../rebuild.zig");
const mechanics = @import("mechanics.zig");

pub const RepairDebtAssessment = enum {
    clear,
    repair,
};

pub fn updateRepairDebt(
    graph: *graph_core.GraphCore,
    adj: *types.NodeAdj,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) void {
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }

    const needs_repair = computeNeedsRepair(graph, adj, side);
    const previous_flag = mechanics.getRepairFlag(adj, side);
    mechanics.setRepairFlag(adj, side, needs_repair);
    if (!previous_flag and needs_repair) mechanics.enqueueRepairDebtBestEffort(graph, node_idx, side);
}

pub fn updateRepairDebtAfterEdgeMutation(
    graph: *graph_core.GraphCore,
    adj: *types.NodeAdj,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
    previous_flag: bool,
) void {
    _ = graph;
    _ = node_idx;
    if (adj.flags.removed) {
        adj.flags.needs_repair_fwd = false;
        adj.flags.needs_repair_rev = false;
        return;
    }
    mechanics.setRepairFlag(adj, side, previous_flag);
}

pub fn computeNeedsRepair(
    graph: *graph_core.GraphCore,
    adj: *const types.NodeAdj,
    comptime side: adjacency.AdjSide,
) bool {
    const published_side = side_adj.sideAdjOfNode(adj.*, side);
    const has_tombstone = published_side.block_count > 0 and rebuild_mod.hasAnyTombstone(
        graph,
        published_side.first_block,
        published_side.block_count,
        published_side.group_count,
        published_side.first_group,
        side,
    );

    if (node_published.NodePublished.isTiny(&published_side)) return has_tombstone;

    const report = layout_debt.analyzeSideLayout(graph, published_side, side) catch return true;

    if (published_side.block_count <= 1) return has_tombstone;
    if (published_side.group_count == 0) return has_tombstone or report.has_underfull_non_tail_block;

    return has_tombstone or report.has_underfull_non_tail_block or report.group_count_exceeded;
}

pub fn assessPublishedRepairDebt(
    graph: *graph_core.GraphCore,
    published_adj: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) RepairDebtAssessment {
    if (published_adj.flags.removed) return .clear;

    const published_side = side_adj.sideAdjOfNode(published_adj, side);
    if (published_side.block_count == 0) return .clear;

    return if (computeNeedsRepair(graph, &published_adj, side)) .repair else .clear;
}

pub fn refreshPublishedRepairDebt(
    graph: *graph_core.GraphCore,
    node: *types.NodeBuffer,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) RepairDebtAssessment {
    const published_adj = node_access.publishedAdjAtConst(graph, .{ .index = node_idx });
    const assessment = assessPublishedRepairDebt(graph, published_adj, side);
    const node_meta = page_ops.nodeMetaAt(graph, .{ .index = node_idx });
    mechanics.writePublishedRepairFlag(node_meta, node, side, assessment == .repair);
    return assessment;
}

pub fn updateRepairDebtSide(
    graph: *graph_core.GraphCore,
    node: *types.NodeBuffer,
    node_idx: u32,
    comptime side: adjacency.AdjSide,
) RepairDebtAssessment {
    return refreshPublishedRepairDebt(graph, node, node_idx, side);
}
