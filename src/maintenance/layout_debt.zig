const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");

pub const LayoutShapeReport = struct {
    grouped_single_block: bool = false,
    chain_is_contiguous: bool = false,
    has_small_non_tail_group: bool = false,
    has_underfull_non_tail_block: bool = false,
    group_count_exceeded: bool = false,
    counted_groups: u16 = 0,
};

pub fn forEachGroupInSide(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_view.group_count == 0) return;
    try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);

    var group_idx = side_view.first_group;
    var visited: u16 = 0;
    while (visited < side_view.group_count) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) return error.CorruptGraph;
        const group = page_ops.groupAtConst(graph, group_idx);
        try callback(graph, context, group_idx, group.*, visited + 1 == side_view.group_count);
        group_idx = group.next;
    }
}

pub fn analyzeSideLayout(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !LayoutShapeReport {
    var report = LayoutShapeReport{};

    if (side_view.block_count <= 1) {
        report.grouped_single_block = side_view.group_count > 0;
        if (side_view.group_count > 0) {
            try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);
            report.group_count_exceeded = side_view.group_count > constants.MAX_GROUPS_PER_NODE;
            report.counted_groups = side_view.group_count;
            report.chain_is_contiguous = true;
        }
        return report;
    }

    if (side_view.group_count == 0) {
        const end = side_view.first_block + side_view.block_count - 1;
        for (side_view.first_block..end) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                report.has_underfull_non_tail_block = true;
                break;
            }
        }
        return report;
    }

    try adjacency.validateSideAdjLayoutForSide(graph, side_view, side);
    report.chain_is_contiguous = true;
    report.group_count_exceeded = side_view.group_count > constants.MAX_GROUPS_PER_NODE;

    var group_idx = side_view.first_group;
    var visited: u16 = 0;
    var previous_group_end: ?u32 = null;
    while (group_idx != constants.END_OF_CHAIN) {
        visited += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        const is_last_group = group.next == constants.END_OF_CHAIN;
        if (previous_group_end) |expected_start| {
            if (group.start != expected_start) report.chain_is_contiguous = false;
        }
        previous_group_end = group.start + group.count;
        if (!is_last_group and group.count < 4) {
            report.has_small_non_tail_group = true;
        }

        const end = if (is_last_group) group.start + group.count - 1 else group.start + group.count;
        for (group.start..end) |block_idx_usize| {
            const block_idx: u32 = @intCast(block_idx_usize);
            const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
            if (@popCount(block.mask) < constants.MIN_OCCUPANCY) {
                report.has_underfull_non_tail_block = true;
                break;
            }
        }
        if (report.has_underfull_non_tail_block and report.has_small_non_tail_group and !report.chain_is_contiguous) {
            // Keep scanning only for counted_groups.
        }
        group_idx = group.next;
    }
    report.counted_groups = visited;
    return report;
}
