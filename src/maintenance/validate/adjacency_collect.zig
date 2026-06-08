const common = @import("common.zig");
const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");

pub const DebugGroupSpan = struct {
    group: u32,
    start: u32,
    count: u16,
};

pub fn appendContiguousBlocks(
    blocks: *std.ArrayList(common.TraversedBlock),
    allocator: std.mem.Allocator,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_index| {
        try blocks.append(allocator, .{ .block_index = @intCast(block_index) });
    }
}

pub fn spansOverlap(a: DebugGroupSpan, b: DebugGroupSpan) bool {
    const a_end = a.start + a.count;
    const b_end = b.start + b.count;
    return a.start < b_end and b.start < a_end;
}

pub fn collectAdjacencyBlocks(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    blocks: *std.ArrayList(common.TraversedBlock),
    comptime side: common.Side,
) !void {
    if (common.blockCount(adjacency, side) == 0) return;

    if (common.groupCount(adjacency, side) == 0) {
        try appendContiguousBlocks(blocks, allocator, common.firstBlock(adjacency, side), common.blockCount(adjacency, side));
        return;
    }

    var seen_spans: [64]DebugGroupSpan = undefined;
    var seen_count: usize = 0;
    const expected_groups = common.groupCount(adjacency, side);
    const first_group_idx = common.firstGroup(adjacency, side);
    const end_group = std.math.add(u32, first_group_idx, expected_groups) catch {
        try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = first_group_idx } });
        return;
    };
    if (end_group > graph.group_count) {
        try violations.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = first_group_idx } });
        return;
    }

    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.groupAtConst(graph, group_idx);
        const current_span = DebugGroupSpan{ .group = group_idx, .start = group.start, .count = group.count };
        for (seen_spans[0..@min(seen_count, seen_spans.len)]) |seen| {
            if (spansOverlap(seen, current_span)) {
                try violations.append(allocator, .{ .blockgroup_overlap = .{ .node = node_id, .group_a = seen.group, .group_b = group_idx } });
            }
        }
        if (seen_count < seen_spans.len) seen_spans[seen_count] = current_span;
        seen_count += 1;

        for (group.start..group.start + group.count) |block_idx_usize| {
            try blocks.append(allocator, .{ .block_index = @intCast(block_idx_usize) });
        }
    }
}
