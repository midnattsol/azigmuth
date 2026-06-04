const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
pub fn edgePointsToRemoved(
    graph: *const graph_core.GraphCore,
    block: anytype,
    slot: u7,
    comptime side: adjacency.AdjSide,
) bool {
    const node_id = switch (side) {
        .fwd => block.edges[slot].destination,
        .rev => block.sources[slot],
    };
    if (node_id >= graph.publishedNodeCount()) return false;
    return page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj().flags.removed;
}

pub fn hasAnyTombstone(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    comptime side: adjacency.AdjSide,
) bool {
    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (edgePointsToRemoved(graph, block, @intCast(slot), side)) return true;
            }
        }
    } else {
        var group_idx = first_group;
        var visited: u16 = 0;
        while (group_idx != constants.END_OF_CHAIN) {
            if (group_idx >= graph.group_count) return false;
            if (visited >= group_count or visited >= graph.group_count) return false;
            visited += 1;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), side);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (edgePointsToRemoved(graph, block, @intCast(slot), side)) return true;
                }
            }
            group_idx = group.next;
        }
    }
    return false;
}
pub fn collectForwardTombstoneDestinations(
    graph: *const graph_core.GraphCore,
    published_adj: types.NodeAdj,
    destinations: *std.ArrayList(u32),
) !void {
    if (published_adj.block_count_fwd == 0) return;

    if (published_adj.group_count_fwd == 0) {
        for (published_adj.first_block_fwd..published_adj.first_block_fwd + published_adj.block_count_fwd) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                const destination = block.edges[slot].destination;
                var seen = false;
                for (destinations.items) |existing| {
                    if (existing == destination) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try destinations.append(graph.allocator, destination);
            }
        }
        return;
    }

    var group_idx = published_adj.first_group_fwd;
    var visited_dests: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (visited_dests >= published_adj.group_count_fwd or visited_dests >= graph.group_count) return error.CorruptGraph;
        visited_dests += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (!edgePointsToRemoved(graph, block, @intCast(slot), .fwd)) continue;
                const destination = block.edges[slot].destination;
                var seen = false;
                for (destinations.items) |existing| {
                    if (existing == destination) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try destinations.append(graph.allocator, destination);
            }
        }
        group_idx = group.next;
    }
}

