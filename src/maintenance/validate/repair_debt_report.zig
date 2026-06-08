const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");

pub fn appendRepairDebtViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation)) !void {
    const node_count = graph.publishedNodeCount();
    for (graph.repair_fwd.items) |node_idx| {
        if (node_idx >= node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_idx } });
        }
    }
    for (graph.repair_rev.items) |node_idx| {
        if (node_idx >= node_count) {
            try violations.append(allocator, .{ .repair_debt_invalid_node = .{ .entry = node_idx } });
        }
    }
}
