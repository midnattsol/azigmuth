const common = @import("common.zig");
const layout_debt = @import("../layout_debt.zig");
const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency_mod = @import("../../adjacency/mod.zig");

fn sideViewOf(adjacency: types.NodeAdj, comptime side: common.Side) types.SideAdj {
    return switch (side) {
        .fwd => .{ .first_block = adjacency.first_block_fwd, .block_count = adjacency.block_count_fwd, .segment_count = adjacency.segment_count_fwd, .first_segment = adjacency.first_segment_fwd },
        .rev => .{ .first_block = adjacency.first_block_rev, .block_count = adjacency.block_count_rev, .segment_count = adjacency.segment_count_rev, .first_segment = adjacency.first_segment_rev },
    };
}

pub fn appendLayoutDebtViolations(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator, violations: *std.ArrayList(types.Violation), node_id: u32, adjacency: types.NodeAdj, comptime side: common.Side) !void {
    const side_view = sideViewOf(adjacency, side);
    if (side_view.segment_count == 0) return;

    const side_tag = switch (side) {
        .fwd => adjacency_mod.AdjSide.fwd,
        .rev => adjacency_mod.AdjSide.rev,
    };
    const report = layout_debt.analyzeSideLayout(graph, side_view, side_tag) catch {
        try violations.append(allocator, .{ .blocksegment_chain_cycle = .{ .node = node_id, .segment = common.firstSegment(adjacency, side) } });
        return;
    };
    if (report.segment_count_exceeded and !common.needsRepairFlag(adjacency, side) and !adjacency.flags.removed) {
        try violations.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
    }
}
