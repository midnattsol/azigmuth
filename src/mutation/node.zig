//! Node-oriented mutation helpers and node removal implementation.

const std = @import("std");
const constants = @import("../constants.zig");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const page_ops = @import("../page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../repair.zig");
const common = @import("common.zig");

fn collectForwardDestinations(graph: *const graph_core.GraphCore, node: types.NodeId, destinations: *std.ArrayList(u32)) !void {
    const published_adj = page_ops.nodeAtConst(graph, node).publishedAdj();
    if (published_adj.block_count_fwd == 0) return;

    if (published_adj.group_count_fwd == 0) {
        const start = published_adj.first_block_fwd;
        const end = start + published_adj.block_count_fwd;
        for (start..end) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                try destinations.append(graph.allocator, block.edges[slot].destination);
            }
        }
        return;
    }

    var group_index = published_adj.first_group_fwd;
    while (group_index != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                try destinations.append(graph.allocator, block.edges[slot].destination);
            }
        }
        group_index = group.next;
    }
}

fn retirePublishedForwardBlocks(graph: *graph_core.GraphCore, published_adj: types.NodeAdj) !void {
    if (published_adj.block_count_fwd == 0) return;

    if (published_adj.group_count_fwd == 0) {
        const start = published_adj.first_block_fwd;
        const end = start + published_adj.block_count_fwd;
        for (start..end) |block_index| {
            try rcu.retireBlockFwd(graph, @intCast(block_index));
        }
        return;
    }

    var group_index = published_adj.first_group_fwd;
    while (group_index != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            try rcu.retireBlockFwd(graph, @intCast(block_index));
        }
        group_index = group.next;
    }
}

fn clearForwardAdjacencyAndMarkRemoved(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    const node_buffer = page_ops.nodeAt(graph, node);
    var claims = try common.tryClaimAdjacencies(node_buffer, node_buffer, node.index, node.index);
    defer claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const published_adj_before = node_buffer.publishedAdj();
    const old_first_group_fwd: ?u32 = if (published_adj_before.group_count_fwd > 0) published_adj_before.first_group_fwd else null;
    const old_group_count_fwd = published_adj_before.group_count_fwd;
    try retirePublishedForwardBlocks(graph, published_adj_before);

    node_buffer.copyPublishedToStaging();
    const staging_adj = node_buffer.stagingAdj();
    staging_adj.first_block_fwd = 0;
    staging_adj.block_count_fwd = 0;
    staging_adj.group_count_fwd = 0;
    staging_adj.first_group_fwd = 0;
    staging_adj.flags.removed = true;
    node_buffer.publishStagingAdj();
    node_buffer.degree_fwd = 0;
    if (old_first_group_fwd) |first_group| common.retireGroupChain(graph, first_group, old_group_count_fwd);
    writer_guard.end();
}

/// Marks `node` as removed and clears all its outgoing edges.
/// Incoming edges to `node` from other nodes persist as tombstoned
/// references until compacted by `repairBudgeted` or during future
/// mutations on those nodes.
pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (node.index >= graph.node_count) return error.InvalidNode;

    var forward_destinations: std.ArrayList(u32) = .empty;
    defer forward_destinations.deinit(graph.allocator);

    try collectForwardDestinations(graph, node, &forward_destinations);
    try clearForwardAdjacencyAndMarkRemoved(graph, node);

    // Remove each reverse entry. The forward adjacency is already cleared,
    // so we handle only the reverse side per destination.
    for (forward_destinations.items) |destination_index| {
        try removeReverseSlot(graph, node.index, destination_index);
    }

    rcu.bumpEpoch(graph);
    rcu.reclaimRetired(graph);
}

/// Removes the reverse-side slot for a single edge (`source_index → destination_index`).
/// Used by removeNode when the forward adjacency has already been cleared.
/// Handles claims, COW, publication, and edge_count decrement for the
/// destination's reverse adjacency only.
fn removeReverseSlot(
    graph: *graph_core.GraphCore,
    source_index: u32,
    destination_index: u32,
) !void {
    const destination_node = page_ops.nodeAt(graph, .{ .index = destination_index });
    var claims = try common.tryClaimAdjacencies(destination_node, destination_node, destination_index, destination_index);
    defer claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const destination_adj = destination_node.publishedAdj();
    const old_first_group_rev: ?u32 = if (destination_adj.group_count_rev > 0) destination_adj.first_group_rev else null;
    const old_group_count_rev = destination_adj.group_count_rev;

    const reverse_found = common.findSlotInAdj(
        graph,
        destination_adj.first_block_rev,
        destination_adj.block_count_rev,
        destination_adj.group_count_rev,
        destination_adj.first_group_rev,
        source_index,
        .rev,
    ) orelse return error.CorruptGraph;

    const reverse_block_before = page_ops.edgeBlockAtConst(graph, reverse_found.block_idx, .rev);
    const reverse_live_before = @popCount(reverse_block_before.mask);
    const reverse_new_live = reverse_live_before - 1;
    const reverse_tail = adjacency.tailBlockIndex(graph, &destination_adj, .rev);
    const reverse_is_tail = reverse_found.block_idx == reverse_tail;
    if (!reverse_is_tail and reverse_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    destination_node.copyPublishedToStaging();
    const destination_staging_adj = destination_node.stagingAdj();

    {
        const old_block = reverse_found.block_idx;
        const new_block = try page_ops.allocBlock(graph, .rev);
        page_ops.edgeBlockAt(graph, new_block, .rev).* = reverse_block_before.*;

        const reverse_block = page_ops.edgeBlockAt(graph, new_block, .rev);
        const live = reverse_live_before;
        var shift: u7 = reverse_found.slot;
        while (shift < live - 1) : (shift += 1) {
            reverse_block.sources[shift] = reverse_block.sources[shift + 1];
        }
        const new_live = live - 1;
        reverse_block.mask = constants.denseMask(@intCast(new_live));

        if (!reverse_is_tail and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try common.rebuildAdjWithReplace(
            graph,
            destination_staging_adj,
            destination_adj.first_block_rev,
            destination_adj.block_count_rev,
            destination_adj.group_count_rev,
            destination_adj.first_group_rev,
            old_block,
            new_block,
            .rev,
        );
        try rcu.retireBlockRev(graph, old_block);
    }

    repair.updateRepairDebt(graph, destination_staging_adj, destination_index, .rev);

    // Self-edges: forward adjacency was already published in the caller;
    // the reverse side here operates on the same node buffer, so publish.
    destination_node.publishStagingAdj();
    common.decrementDegree(&destination_node.degree_rev);
    if (old_first_group_rev) |first_group| common.retireGroupChain(graph, first_group, old_group_count_rev);

    _ = graph.edge_count.fetchSub(1, .monotonic);
    writer_guard.end();
}
