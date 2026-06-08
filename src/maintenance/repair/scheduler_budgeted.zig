//! Budgeted repair loops and flush entry points.

const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const debt_mod = @import("debt.zig");
const scheduler_apply = @import("scheduler_apply.zig");
const scheduler_scan = @import("scheduler_scan.zig");

fn repairBudgetedWork(
    graph: *graph_core.GraphCore,
    max_nodes: usize,
    processed_nodes: *std.AutoHashMap(u32, void),
    allow_tombstone_scan: bool,
) !usize {
    var total_compacted: usize = 0;

    while (total_compacted < max_nodes) {
        const node_idx = scheduler_scan.nextRepairDebtNode(graph, processed_nodes, allow_tombstone_scan) orelse break;
        try processed_nodes.put(node_idx, {});

        if (try scheduler_apply.repairBothSides(graph, .{ .index = node_idx })) total_compacted += 1;
    }

    return total_compacted;
}

fn flushTombstoneDebt(
    graph: *graph_core.GraphCore,
    max_nodes: usize,
    processed_nodes: *std.AutoHashMap(u32, void),
) !usize {
    var total_compacted: usize = 0;

    while (total_compacted < max_nodes) {
        const node_idx = scheduler_scan.findTombstoneDebtByScan(graph) orelse break;
        if (!scheduler_scan.isEligibleRepairCandidate(graph, processed_nodes, node_idx)) continue;
        try processed_nodes.put(node_idx, {});

        if (try scheduler_apply.repairBothSides(graph, .{ .index = node_idx })) total_compacted += 1;
    }

    return total_compacted;
}

/// Repairs up to `max_nodes` distinct nodes from the queued repair debt sources.
pub fn repairBudgeted(graph: *graph_core.GraphCore, max_nodes: usize) !usize {
    if (graph.active_repairers.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        return error.ConcurrentMutation;
    }
    defer graph.active_repairers.store(0, .release);

    var processed_nodes = std.AutoHashMap(u32, void).init(graph.allocator);
    defer processed_nodes.deinit();

    const total_compacted = try repairBudgetedWork(graph, max_nodes, &processed_nodes, false);
    if (total_compacted > 0) {
        rcu.bumpEpoch(graph);
    }

    return total_compacted;
}

/// Runs a full repair pass and returns a summary of work and remaining debt.
pub fn flushRepairs(graph: *graph_core.GraphCore) !types.RepairFlushSummary {
    if (graph.active_repairers.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        return error.ConcurrentMutation;
    }
    defer graph.active_repairers.store(0, .release);

    const node_count = graph.publishedNodeCount();
    if (node_count == 0) {
        return .{
            .repaired_nodes = 0,
            .pass_count = 0,
            .remaining_repair_fwd = 0,
            .remaining_repair_rev = 0,
            .remaining_structural_debt = false,
        };
    }

    var processed_nodes = std.AutoHashMap(u32, void).init(graph.allocator);
    defer processed_nodes.deinit();

    const repaired_flagged = try repairBudgetedWork(graph, node_count, &processed_nodes, false);
    const repaired_scanned = try flushTombstoneDebt(graph, node_count - repaired_flagged, &processed_nodes);
    const repaired_nodes = repaired_flagged + repaired_scanned;

    if (repaired_nodes > 0) {
        rcu.bumpEpoch(graph);
    }

    const remaining_repair_fwd = debt_mod.countNodesWithRepairFlag(graph, .fwd);
    const remaining_repair_rev = debt_mod.countNodesWithRepairFlag(graph, .rev);

    return .{
        .repaired_nodes = repaired_nodes,
        .pass_count = if (repaired_scanned > 0) 2 else 1,
        .remaining_repair_fwd = remaining_repair_fwd,
        .remaining_repair_rev = remaining_repair_rev,
        .remaining_structural_debt = remaining_repair_fwd > 0 or remaining_repair_rev > 0,
    };
}
