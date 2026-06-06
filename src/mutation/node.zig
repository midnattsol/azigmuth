//! Node-oriented mutation helpers and node removal implementation.

const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../maintenance/repair.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");

const DestinationUpdate = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    published_adj_before: types.NodeAdj,
    staging_adj_after: types.NodeAdj,
    new_degree_rev: u22,
    fwd_degree_delta: u22,
    needs_reverse_retire: bool = false,
};

const RelatedNode = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    claims: common.ClaimedNodeSides,
    needs_reverse_cleanup: bool = false,
    fwd_degree_delta: u22 = 0,
};

fn toU22Degree(count: usize) u22 {
    return @as(u22, @intCast(count));
}

fn collectForwardDestinations(graph: *const graph_core.GraphCore, node: types.NodeId, destinations: *std.ArrayList(u32)) !void {
    const node_count = graph.publishedNodeCount();
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();
    const degree_fwd = node_buffer.loadPublishedMeta().degree_fwd;
    try destinations.ensureTotalCapacity(graph.allocator, degree_fwd);
    if (published_adj.block_count_fwd == 0) return;

    if (published_adj.group_count_fwd == 0) {
        const start = published_adj.first_block_fwd;
        const end = start + published_adj.block_count_fwd;
        for (start..end) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const destination = block.edges[slot].destination;
                if (destination >= node_count) return error.CorruptGraph;
                try destinations.append(graph.allocator, destination);
            }
        }
        return;
    }

    var group_index = published_adj.first_group_fwd;
    var visited: u16 = 0;
    while (visited < published_adj.group_count_fwd) : (visited += 1) {
        if (group_index == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), .fwd);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const destination = block.edges[slot].destination;
                if (destination >= node_count) return error.CorruptGraph;
                try destinations.append(graph.allocator, destination);
            }
        }
        group_index = group.next;
    }
}

fn collectReverseSources(graph: *const graph_core.GraphCore, node: types.NodeId, sources: *std.ArrayList(u32)) !void {
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();
    const degree_rev = node_buffer.loadPublishedMeta().degree_rev;
    try sources.ensureTotalCapacity(graph.allocator, degree_rev);
    if (published_adj.block_count_rev == 0) return;

    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                try sources.append(graph.allocator, block.sources[slot]);
            }
        }
        return;
    }

    var group_idx = published_adj.first_group_rev;
    var visited: u16 = 0;
    while (visited < published_adj.group_count_rev) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                try sources.append(graph.allocator, block.sources[slot]);
            }
        }
        group_idx = group.next;
    }
}

/// Collects a node that must be touched during removeNode.
///
/// Forward-degree decrements on predecessors are published via CAS on
/// `published_meta` (see `publishMetaFwdUpdated` in `claims.zig`), so claiming
/// `fwd_claim` on the predecessor is unnecessary for that path.  Only
/// `rev_claim` is needed for reverse-side cleanup (block replacement).
/// This matches the RFC Phase 2 contract: predecessor updates are CAS-only
/// and do not require `fwd_claim`.
fn markRelatedNode(
    graph: *graph_core.GraphCore,
    related_nodes: *std.ArrayList(RelatedNode),
    related_node_index: *std.AutoHashMap(u32, usize),
    node_index: u32,
    mark_reverse_cleanup: bool,
    fwd_degree_delta: u22,
) !void {
    if (related_node_index.get(node_index)) |entry_idx| {
        const entry = &related_nodes.items[entry_idx];
        if (mark_reverse_cleanup) try entry.claims.ensureRev();
        // fwd_claim is NOT needed for visible_fwd_decrement — CAS on
        // published_meta provides the atomicity directly.
        entry.needs_reverse_cleanup = entry.needs_reverse_cleanup or mark_reverse_cleanup;
        entry.fwd_degree_delta += fwd_degree_delta;
        return;
    }

    const node_buffer = page_ops.nodeAt(graph, .{ .index = node_index });
    const claims = try common.tryClaimNodeSides(node_buffer, false, mark_reverse_cleanup);
    try related_nodes.append(graph.allocator, .{
        .node_index = node_index,
        .node_buffer = node_buffer,
        .claims = claims,
        .needs_reverse_cleanup = mark_reverse_cleanup,
        .fwd_degree_delta = fwd_degree_delta,
    });
    try related_node_index.put(node_index, related_nodes.items.len - 1);
}

fn countDistinctNonSelfDestinations(destinations: []const u32, source_index: u32) usize {
    var total: usize = 0;
    for (destinations) |destination_index| {
        if (destination_index != source_index) total += 1;
    }
    return total;
}

fn countVisibleForwardEdges(graph: *const graph_core.GraphCore, destinations: []const u32) usize {
    var total: usize = 0;
    for (destinations) |destination_index| {
        if (node_validity.isNodeLiveIndex(graph, destination_index)) total += 1;
    }
    return total;
}

fn countVisibleIncomingEdgesExcludingSelf(graph: *const graph_core.GraphCore, published_adj: types.NodeAdj, self_index: u32) usize {
    if (published_adj.block_count_rev == 0) return 0;

    var total: usize = 0;
    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const source_index = block.sources[slot];
                if (source_index == self_index) continue;
                if (node_validity.isNodeLiveIndex(graph, source_index)) total += 1;
            }
        }
        return total;
    }

    var group_idx = published_adj.first_group_rev;
    var visited: u16 = 0;
    while (visited < published_adj.group_count_rev) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const source_index = block.sources[slot];
                if (source_index == self_index) continue;
                if (node_validity.isNodeLiveIndex(graph, source_index)) total += 1;
            }
        }
        group_idx = group.next;
    }
    return total;
}

pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !types.NodeRemovalSummary {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, node);
    var source_claims = try common.tryClaimNodeSides(source_node, true, true);
    defer source_claims.release();

    const source_adj_before = source_node.publishedAdj();
    if (!node_validity.snapshotIsLive(source_adj_before)) return error.InvalidNode;

    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .fwd);
    try adjacency.validateNodeAdjLayout(graph, source_adj_before, .rev);

    var forward_destinations: std.ArrayList(u32) = .empty;
    defer forward_destinations.deinit(graph.allocator);
    try collectForwardDestinations(graph, node, &forward_destinations);

    // RFC §A.25: reject duplicate outgoing destinations before any publish.
    {
        if (!graph.multigraph_enabled) {
            var seen = std.AutoHashMap(u32, void).init(graph.allocator);
            defer seen.deinit();
            for (forward_destinations.items) |destination_index| {
                const entry = try seen.getOrPut(destination_index);
                if (entry.found_existing) return error.CorruptGraph;
            }
        }
    }

    var reverse_sources: std.ArrayList(u32) = .empty;
    defer reverse_sources.deinit(graph.allocator);
    try collectReverseSources(graph, node, &reverse_sources);

    var self_edge_count: u32 = 0;
    for (forward_destinations.items) |destination_index| {
        if (destination_index == node.index) self_edge_count += 1;
    }

    // Validate incoming reverse completeness before any publish.
    // Reject invalid, removed, and duplicate sources.  Verify that every
    // live predecessor still has a forward edge to the removed node.
    // Compare the validated count against the exact published degree_rev.
    const source_meta = source_node.loadPublishedMeta();
    const predecessor_reader = try rcu.readerEnter(graph);
    defer rcu.readerExit(graph, predecessor_reader);
    {
        var valid_count: u22 = 0;
        var self_count: u22 = 0;
        if (graph.multigraph_enabled) {
            var source_counts = std.AutoHashMap(u32, u32).init(graph.allocator);
            defer source_counts.deinit();

            for (reverse_sources.items) |source_index| {
                if (source_index >= graph.publishedNodeCount()) return error.CorruptGraph;
                if (!node_validity.isNodeLiveIndex(graph, source_index)) continue;

                const entry = try source_counts.getOrPut(source_index);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }

            if (source_counts.get(node.index)) |self_rev| {
                self_count = @intCast(self_rev);
                if (self_count != self_edge_count) return error.CorruptGraph;
            } else if (self_edge_count > 0) {
                return error.CorruptGraph;
            }

            var source_iter = source_counts.iterator();
            while (source_iter.next()) |kv| {
                const source_index = kv.key_ptr.*;
                if (source_index == node.index) continue;

                const source_fwd = page_ops.nodeAtConst(graph, .{ .index = source_index }).publishedAdj();
                const forward_count = try adjacency.countForwardDestinationMatchesChecked(
                    graph,
                    source_fwd.first_block_fwd,
                    source_fwd.block_count_fwd,
                    source_fwd.group_count_fwd,
                    source_fwd.first_group_fwd,
                    node.index,
                );
                const reverse_count = kv.value_ptr.*;
                if (forward_count != reverse_count) return error.CorruptGraph;
                valid_count += @as(u22, @intCast(reverse_count));
                if (valid_count + self_count > source_meta.degree_rev) return error.CorruptGraph;
            }
        } else {
            var seen_incoming = std.AutoHashMap(u32, void).init(graph.allocator);
            defer seen_incoming.deinit();
            for (reverse_sources.items) |source_index| {
                if (source_index >= graph.publishedNodeCount()) return error.CorruptGraph;
                if (source_index == node.index) {
                    self_count += 1;
                    if (self_count > 1 or self_edge_count == 0) return error.CorruptGraph;
                    continue;
                }
                if (!node_validity.isNodeLiveIndex(graph, source_index)) continue;

                {
                    const entry = try seen_incoming.getOrPut(source_index);
                    if (entry.found_existing) return error.CorruptGraph;
                }

                const source_fwd = page_ops.nodeAtConst(graph, .{ .index = source_index }).publishedAdj();
                if (!(try adjacency.hasEdgeInAdjChecked(graph, source_fwd, node.index))) return error.CorruptGraph;

                valid_count += 1;
                if (valid_count + self_count > source_meta.degree_rev) return error.CorruptGraph;
            }
        }
        if (valid_count + self_count != source_meta.degree_rev) return error.CorruptGraph;
    }

    var related_nodes = try std.ArrayList(RelatedNode).initCapacity(
        graph.allocator,
        countDistinctNonSelfDestinations(forward_destinations.items, node.index) +
            countVisibleIncomingEdgesExcludingSelf(graph, source_adj_before, node.index),
    );
    var related_node_index = std.AutoHashMap(u32, usize).init(graph.allocator);
    defer {
        var remaining = related_nodes.items.len;
        while (remaining > 0) {
            remaining -= 1;
            related_nodes.items[remaining].claims.release();
        }
        related_nodes.deinit(graph.allocator);
        related_node_index.deinit();
    }

    for (forward_destinations.items) |destination_index| {
        if (destination_index == node.index) continue;
        try markRelatedNode(graph, &related_nodes, &related_node_index, destination_index, true, 0);
    }
    for (reverse_sources.items) |source_index| {
        if (source_index == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, source_index)) continue;
        try markRelatedNode(graph, &related_nodes, &related_node_index, source_index, false, 1);
    }

    var scratch = common.MutationScratch{};
    defer {
        scratch.cleanup(graph);
        scratch.deinit(graph.allocator);
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    var destination_updates = try std.ArrayList(DestinationUpdate).initCapacity(graph.allocator, related_nodes.items.len);
    defer destination_updates.deinit(graph.allocator);

    for (related_nodes.items) |*related| {
        if (related.needs_reverse_cleanup) {
            const destination_adj_before = related.node_buffer.publishedAdj();
            var rb = try repair.prepareReverseWithoutSource(
                graph,
                destination_adj_before.first_block_rev,
                destination_adj_before.block_count_rev,
                destination_adj_before.group_count_rev,
                destination_adj_before.first_group_rev,
                node.index,
                graph.allocator,
            );
            defer rb.new_blocks.deinit(graph.allocator);

            scratch.adoptBlocks(graph.allocator, .rev, rb.new_blocks.items) catch |err| {
                for (rb.new_blocks.items) |bid| page_ops.freeBlock(graph, bid, .rev);
                return err;
            };

            var destination_staging_adj = destination_adj_before;
            {
                var tmp: types.SideAdj = undefined;
                try common.buildSideFromBlocks(&tmp, graph, rb.new_blocks.items, &scratch);
                destination_staging_adj.first_block_rev = tmp.first_block;
                destination_staging_adj.block_count_rev = tmp.block_count;
                destination_staging_adj.group_count_rev = tmp.group_count;
                destination_staging_adj.first_group_rev = tmp.first_group;
            }
            const live_after: usize = rb.live_after;
            // Removed nodes always have logical degree 0 regardless of
            // residual reverse structure after tombstone cleanup.
            const new_rev_deg = if (destination_adj_before.flags.removed) @as(u22, 0) else toU22Degree(live_after);
            repair.updateRepairDebt(graph, &destination_staging_adj, related.node_index, .rev);

            try destination_updates.append(graph.allocator, .{
                .node_index = related.node_index,
                .node_buffer = related.node_buffer,
                .published_adj_before = destination_adj_before,
                .staging_adj_after = destination_staging_adj,
                .new_degree_rev = new_rev_deg,
                .fwd_degree_delta = related.fwd_degree_delta,
                .needs_reverse_retire = true,
            });
        } else if (related.fwd_degree_delta > 0) {
            try destination_updates.append(graph.allocator, .{
                .node_index = related.node_index,
                .node_buffer = related.node_buffer,
                .published_adj_before = related.node_buffer.publishedAdj(),
                .staging_adj_after = related.node_buffer.publishedAdj(),
                .new_degree_rev = related.node_buffer.loadPublishedMeta().degree_rev,
                .fwd_degree_delta = related.fwd_degree_delta,
            });
        }
    }

    const removed_visible_edge_count = countVisibleForwardEdges(graph, forward_destinations.items) +
        countVisibleIncomingEdgesExcludingSelf(graph, source_adj_before, node.index);

    var source_staging_adj = source_adj_before;
    if (self_edge_count > 0) {
        var rb = try repair.prepareReverseWithoutSource(
            graph,
            source_adj_before.first_block_rev,
            source_adj_before.block_count_rev,
            source_adj_before.group_count_rev,
            source_adj_before.first_group_rev,
            node.index,
            graph.allocator,
        );
        defer rb.new_blocks.deinit(graph.allocator);

        scratch.adoptBlocks(graph.allocator, .rev, rb.new_blocks.items) catch |err| {
            for (rb.new_blocks.items) |bid| page_ops.freeBlock(graph, bid, .rev);
            return err;
        };
        {
            var tmp: types.SideAdj = undefined;
            try common.buildSideFromBlocks(&tmp, graph, rb.new_blocks.items, &scratch);
            source_staging_adj.first_block_rev = tmp.first_block;
            source_staging_adj.block_count_rev = tmp.block_count;
            source_staging_adj.group_count_rev = tmp.group_count;
            source_staging_adj.first_group_rev = tmp.first_group;
        }
    }

    source_staging_adj.first_block_fwd = 0;
    source_staging_adj.block_count_fwd = 0;
    source_staging_adj.group_count_fwd = 0;
    source_staging_adj.first_group_fwd = 0;
    source_staging_adj.flags.removed = true;
    source_staging_adj.flags.needs_repair_fwd = false;
    source_staging_adj.flags.needs_repair_rev = false;

    // Publish predecessor-side degree/repair updates before tombstoning the
    // removed node. Readers may therefore observe a transient mixed-version
    // view across endpoints while removeNode is in flight; the operation only
    // guarantees logical consistency after it returns.
    //
    // Forward-degree decrements use the meta-only CAS helper
    // (`publishMetaFwdDeltaUpdated`) which does NOT require `fwd_claim` on the
    // predecessor — the 64-bit CAS on `published_meta` provides the atomicity
    // (RFC Phase 2 §concurrency note).
    var predecessor_nodes_with_forward_tombstone: u32 = 0;
    var destination_nodes_with_reverse_cleanup: u32 = 0;
    for (destination_updates.items) |update| {
        if (update.fwd_degree_delta > 0) {
            predecessor_nodes_with_forward_tombstone += 1;
            const meta = update.node_buffer.loadPublishedMeta();
            _ = common.publishMetaFwdDeltaUpdated(update.node_buffer, meta, meta.needs_repair_fwd, update.fwd_degree_delta);
        }
        if (update.needs_reverse_retire) {
            destination_nodes_with_reverse_cleanup += 1;
            common.publishRevAdj(update.node_buffer, update.staging_adj_after, update.new_degree_rev);
        }
    }

    common.publishBothAdj(source_node, source_staging_adj, 0, 0);

    // With the target node now marked removed, recompute forward repair debt
    // on each live predecessor.  Their forward adjacency still contains a
    // tombstoned reference that needs compaction, and the flag makes it
    // immediately discoverable by repairBudgeted.
    for (destination_updates.items) |update| {
        if (update.fwd_degree_delta > 0) {
            repair.updateRepairDebtSide(graph, update.node_buffer, update.node_index, .fwd);
        }
    }

    for (destination_updates.items) |update| {
        if (update.needs_reverse_retire) {
            try common.retireSide(graph, update.published_adj_before, .rev);
        }
    }
    try common.retireSide(graph, source_adj_before, .fwd);
    if (self_edge_count > 0) {
        try common.retireSide(graph, source_adj_before, .rev);
    }

    scratch.disarm();
    _ = graph.edge_count.fetchSub(@as(u64, @intCast(removed_visible_edge_count)), .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return .{
        .removed_visible_edges = @intCast(removed_visible_edge_count),
        .related_live_nodes_touched = @intCast(destination_updates.items.len),
        .predecessor_nodes_with_forward_tombstone = predecessor_nodes_with_forward_tombstone,
        .destination_nodes_with_reverse_cleanup = destination_nodes_with_reverse_cleanup,
        .left_forward_repair_debt = predecessor_nodes_with_forward_tombstone > 0,
    };
}
