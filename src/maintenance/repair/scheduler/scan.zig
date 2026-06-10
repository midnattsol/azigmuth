//! Repair candidate selection from explicit debt sources.

const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_validity = @import("../../../core/node_validity.zig");
const debt_mod = @import("../debt.zig");

/// Returns whether one node is live and has not already been processed in this pass.
pub fn isEligibleRepairCandidate(graph: *const graph_core.GraphCore, processed_nodes: *const std.AutoHashMap(u32, void), node_idx: u32) bool {
    if (processed_nodes.contains(node_idx)) return false;
    return node_validity.isNodeLiveIndex(graph, node_idx);
}

/// Picks the next repair candidate from queues and published repair flags.
pub fn nextRepairDebtNode(
    graph: *graph_core.GraphCore,
    processed_nodes: *const std.AutoHashMap(u32, void),
) ?u32 {
    if (debt_mod.popRepairDebtBestEffort(graph, .fwd)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.popRepairDebtBestEffort(graph, .rev)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .fwd)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    if (debt_mod.findRepairDebtByFlag(graph, .rev)) |node_idx| {
        if (isEligibleRepairCandidate(graph, processed_nodes, node_idx)) return node_idx;
    }
    return null;
}
