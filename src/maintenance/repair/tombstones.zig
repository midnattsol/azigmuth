const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency.zig");
const rcu = @import("../../rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../side_adj.zig");
const debt_mod = @import("debt.zig");

const TombstoneProbe = struct {
    found: bool = false,
};

fn stopOnTombstone(
    graph: *const graph_core.GraphCore,
    probe: *TombstoneProbe,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    if (!edgePointsToRemoved(graph, block, slot, side)) return;
    probe.found = true;
    return error.TombstoneFound;
}

fn appendUniqueDestination(
    allocator: std.mem.Allocator,
    destinations: *std.ArrayList(u32),
    destination: u32,
) !void {
    for (destinations.items) |existing| {
        if (existing == destination) return;
    }
    try destinations.append(allocator, destination);
}

fn collectForwardTombstoneDestination(
    graph: *const graph_core.GraphCore,
    destinations: *std.ArrayList(u32),
    block_idx: u32,
    slot: u7,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    if (!edgePointsToRemoved(graph, block, slot, .fwd)) return;
    try appendUniqueDestination(graph.allocator, destinations, block.edges[slot].destination);
}
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
    return node_validity.isNodeRemovedIndex(graph, node_id);
}

pub fn hasAnyTombstone(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    comptime side: adjacency.AdjSide,
) bool {
    var probe = TombstoneProbe{};
    side_adj.forEachSlotInSide(
        graph,
        .{
            .first_block = first_block,
            .block_count = block_count,
            .group_count = group_count,
            .first_group = first_group,
        },
        side,
        &probe,
        struct {
            fn callback(
                inner_graph: *const graph_core.GraphCore,
                inner_probe: *TombstoneProbe,
                block_idx: u32,
                slot: u7,
            ) !void {
                try stopOnTombstone(inner_graph, inner_probe, block_idx, slot, side);
            }
        }.callback,
    ) catch |err| {
        if (err == error.TombstoneFound) return true;
        return true;
    };

    return probe.found;
}

pub fn collectForwardTombstones(
    graph: *const graph_core.GraphCore,
    published_adj: types.NodeAdj,
    destinations: *std.ArrayList(u32),
) !void {
    try side_adj.forEachSlotInSide(
        graph,
        side_adj.sideAdjOfNode(published_adj, .fwd),
        .fwd,
        destinations,
        collectForwardTombstoneDestination,
    );
}
