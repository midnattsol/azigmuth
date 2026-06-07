//! Node-oriented mutation helpers and node removal implementation.

const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../maintenance/repair.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");

const RelatedNode = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    claims: common.ClaimedNodeSides,
    fwd_degree_delta: u22,
    rev_degree_delta: u22,
};

const RemovalScan = struct {
    forward_destinations: std.ArrayList(u32) = .empty,
    reverse_sources: std.ArrayList(u32) = .empty,
    self_edge_count: u32 = 0,
    visible_forward: u32 = 0,
    visible_incoming: u32 = 0,

    fn deinit(self: *RemovalScan, allocator: std.mem.Allocator) void {
        self.forward_destinations.deinit(allocator);
        self.reverse_sources.deinit(allocator);
    }
};

const RemoveCounts = struct {
    predecessors: u32 = 0,
    destinations: u32 = 0,
};

const ForwardDestinationCollection = struct {
    source_idx: u32,
    node_count: u32,
    scan: *RemovalScan,
};

fn appendForwardDestination(
    graph: *const graph_core.GraphCore,
    collection: *ForwardDestinationCollection,
    block_idx: u32,
    slot: u7,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const destination = block.edges[slot].destination;
    if (destination >= collection.node_count) return error.CorruptGraph;
    try collection.scan.forward_destinations.append(graph.allocator, destination);
    if (node_validity.isNodeLiveIndex(graph, destination)) {
        collection.scan.visible_forward += 1;
    }
    if (destination == collection.source_idx) {
        collection.scan.self_edge_count += 1;
    }
}

const ReverseSourceCollection = struct {
    node_count: u32,
    source_idx: u32,
    scan: *RemovalScan,
};

fn appendReverseSource(
    graph: *const graph_core.GraphCore,
    collection: *ReverseSourceCollection,
    block_idx: u32,
    slot: u7,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const source_idx = block.sources[slot];
    try collection.scan.reverse_sources.append(graph.allocator, source_idx);
    if (source_idx >= collection.node_count) return error.CorruptGraph;
    if (source_idx != collection.source_idx and node_validity.isNodeLiveIndex(graph, source_idx)) {
        collection.scan.visible_incoming += 1;
    }
}

fn collectForwardDestinations(graph: *const graph_core.GraphCore, node: types.NodeId, scan: *RemovalScan) !void {
    const node_count = graph.publishedNodeCount();
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();

    var collection = ForwardDestinationCollection{
        .source_idx = node.index,
        .node_count = node_count,
        .scan = scan,
    };
    try common.forEachSlotInSide(
        graph,
        common.sideAdjOfNode(published_adj, .fwd),
        .fwd,
        &collection,
        appendForwardDestination,
    );
}

fn collectReverseSources(graph: *const graph_core.GraphCore, node: types.NodeId, scan: *RemovalScan) !void {
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();

    var collection = ReverseSourceCollection{
        .node_count = graph.publishedNodeCount(),
        .source_idx = node.index,
        .scan = scan,
    };
    try common.forEachSlotInSide(
        graph,
        common.sideAdjOfNode(published_adj, .rev),
        .rev,
        &collection,
        appendReverseSource,
    );
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
    need_rev_claim: bool,
    fwd_degree_delta: u22,
    rev_degree_delta: u22,
) !void {
    if (related_node_index.get(node_index)) |entry_idx| {
        const entry = &related_nodes.items[entry_idx];
        if (need_rev_claim) try entry.claims.ensureRev();
        entry.fwd_degree_delta += fwd_degree_delta;
        entry.rev_degree_delta += rev_degree_delta;
        return;
    }

    const node_buffer = page_ops.nodeAt(graph, .{ .index = node_index });
    const claims = try common.tryClaimNodeSides(node_buffer, false, need_rev_claim);
    try related_nodes.append(graph.allocator, .{
        .node_index = node_index,
        .node_buffer = node_buffer,
        .claims = claims,
        .fwd_degree_delta = fwd_degree_delta,
        .rev_degree_delta = rev_degree_delta,
    });
    try related_node_index.put(node_index, related_nodes.items.len - 1);
}

fn releaseRelatedNodes(related_nodes: *std.ArrayList(RelatedNode), allocator: std.mem.Allocator) void {
    var remaining = related_nodes.items.len;
    while (remaining > 0) {
        remaining -= 1;
        related_nodes.items[remaining].claims.release();
    }
    related_nodes.deinit(allocator);
}

fn scanNode(graph: *const graph_core.GraphCore, node: types.NodeId) !RemovalScan {
    var scan = RemovalScan{};
    errdefer scan.deinit(graph.allocator);

    try collectForwardDestinations(graph, node, &scan);
    try collectReverseSources(graph, node, &scan);

    return scan;
}

fn validateForwardDestinations(graph: *graph_core.GraphCore, forward_destinations: []const u32) !void {
    if (graph.multigraph_enabled) return;

    var seen = std.AutoHashMap(u32, void).init(graph.allocator);
    defer seen.deinit();
    for (forward_destinations) |destination_idx| {
        const entry = try seen.getOrPut(destination_idx);
        if (entry.found_existing) return error.CorruptGraph;
    }
}

fn validateForwardView(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    scan: *const RemovalScan,
) !void {
    var destination_counts = std.AutoHashMap(u32, u32).init(graph.allocator);
    defer destination_counts.deinit();

    for (scan.forward_destinations.items) |destination_idx| {
        if (destination_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, destination_idx)) continue;

        const entry = try destination_counts.getOrPut(destination_idx);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var destination_iter = destination_counts.iterator();
    while (destination_iter.next()) |kv| {
        const destination_idx = kv.key_ptr.*;
        const destination_adj = page_ops.nodeAtConst(graph, .{ .index = destination_idx }).publishedAdj();
        const reverse_count = try repair.countReverseMatches(
            graph,
            destination_adj.first_block_rev,
            destination_adj.block_count_rev,
            destination_adj.group_count_rev,
            destination_adj.first_group_rev,
            node.index,
        );
        if (reverse_count != kv.value_ptr.*) return error.CorruptGraph;
    }
}

fn validateReverseView(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    source_node: *types.NodeBuffer,
    scan: *const RemovalScan,
) !void {
    const source_meta = source_node.loadPublishedMeta();
    const predecessor_reader = try rcu.readerEnter(graph);
    defer rcu.readerExit(graph, predecessor_reader);

    var valid_count: u22 = 0;
    var self_count: u22 = 0;
    if (graph.multigraph_enabled) {
        var source_counts = std.AutoHashMap(u32, u32).init(graph.allocator);
        defer source_counts.deinit();

        for (scan.reverse_sources.items) |source_idx| {
            if (source_idx >= graph.publishedNodeCount()) return error.CorruptGraph;
            if (!node_validity.isNodeLiveIndex(graph, source_idx)) continue;

            const entry = try source_counts.getOrPut(source_idx);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }

        if (source_counts.get(node.index)) |self_rev| {
            self_count = @intCast(self_rev);
            if (self_count != scan.self_edge_count) return error.CorruptGraph;
        } else if (scan.self_edge_count > 0) {
            return error.CorruptGraph;
        }

        var source_iter = source_counts.iterator();
        while (source_iter.next()) |kv| {
            const source_idx = kv.key_ptr.*;
            if (source_idx == node.index) continue;

            const source_fwd = page_ops.nodeAtConst(graph, .{ .index = source_idx }).publishedAdj();
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
        for (scan.reverse_sources.items) |source_idx| {
            if (source_idx >= graph.publishedNodeCount()) return error.CorruptGraph;
            if (source_idx == node.index) {
                self_count += 1;
                if (self_count > 1 or scan.self_edge_count == 0) return error.CorruptGraph;
                continue;
            }
            if (!node_validity.isNodeLiveIndex(graph, source_idx)) continue;

            const entry = try seen_incoming.getOrPut(source_idx);
            if (entry.found_existing) return error.CorruptGraph;

            const source_fwd = page_ops.nodeAtConst(graph, .{ .index = source_idx }).publishedAdj();
            if (!(try adjacency.hasEdgeInAdjChecked(graph, source_fwd, node.index))) return error.CorruptGraph;

            valid_count += 1;
            if (valid_count + self_count > source_meta.degree_rev) return error.CorruptGraph;
        }
    }

    if (valid_count + self_count != source_meta.degree_rev) return error.CorruptGraph;
}

fn collectRelated(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    scan: *const RemovalScan,
) !struct { nodes: std.ArrayList(RelatedNode), index: std.AutoHashMap(u32, usize) } {
    var related_nodes = try std.ArrayList(RelatedNode).initCapacity(
        graph.allocator,
        scan.forward_destinations.items.len + scan.visible_incoming,
    );
    errdefer releaseRelatedNodes(&related_nodes, graph.allocator);

    var related_index = std.AutoHashMap(u32, usize).init(graph.allocator);
    errdefer related_index.deinit();

    for (scan.forward_destinations.items) |destination_idx| {
        if (destination_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, destination_idx)) continue;
        try markRelatedNode(graph, &related_nodes, &related_index, destination_idx, true, 0, 1);
    }
    for (scan.reverse_sources.items) |source_idx| {
        if (source_idx == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, source_idx)) continue;
        try markRelatedNode(graph, &related_nodes, &related_index, source_idx, true, 1, 0);
    }

    return .{ .nodes = related_nodes, .index = related_index };
}

fn buildRemovedAdj(
    source_adj: types.NodeAdj,
) types.NodeAdj {
    var removed_adj = source_adj;
    removed_adj.first_block_fwd = 0;
    removed_adj.block_count_fwd = 0;
    removed_adj.group_count_fwd = 0;
    removed_adj.first_group_fwd = 0;
    removed_adj.flags.removed = true;
    removed_adj.flags.needs_repair_fwd = false;
    removed_adj.flags.needs_repair_rev = false;
    return removed_adj;
}

fn publishUpdates(related_nodes: []const RelatedNode) RemoveCounts {
    var counts = RemoveCounts{};
    for (related_nodes) |related| {
        if (related.fwd_degree_delta > 0) counts.predecessors += 1;
        if (related.rev_degree_delta > 0) counts.destinations += 1;
        if (related.fwd_degree_delta == 0 and related.rev_degree_delta == 0) continue;

        const meta = related.node_buffer.loadPublishedMeta();
        if (meta.removed) continue;
        if (related.fwd_degree_delta > 0 and related.rev_degree_delta > 0) {
            _ = common.publishMetaBothDeltaUpdated(related.node_buffer, meta, .{
                .needs_repair_fwd = true,
                .needs_repair_rev = true,
                .removed = false,
            }, related.fwd_degree_delta, related.rev_degree_delta);
            continue;
        }

        if (related.fwd_degree_delta > 0) {
            _ = common.publishMetaFwdDeltaUpdated(related.node_buffer, meta, true, related.fwd_degree_delta);
        }
        if (related.rev_degree_delta > 0) {
            _ = common.publishMetaRevDeltaUpdated(related.node_buffer, meta, true, related.rev_degree_delta);
        }
    }
    return counts;
}

fn retireRemoveNode(
    graph: *graph_core.GraphCore,
    source_adj: types.NodeAdj,
) !void {
    try common.retireSide(graph, source_adj, .fwd);
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

    var scan = try scanNode(graph, node);
    defer scan.deinit(graph.allocator);

    try validateForwardDestinations(graph, scan.forward_destinations.items);
    try validateForwardView(graph, node, &scan);
    try validateReverseView(graph, node, source_node, &scan);

    var related = try collectRelated(graph, node, &scan);
    defer {
        releaseRelatedNodes(&related.nodes, graph.allocator);
        related.index.deinit();
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const removed_visible_edge_count = scan.visible_forward + scan.visible_incoming;

    const source_staging_adj = buildRemovedAdj(source_adj_before);

    // Publish predecessor-side degree/repair updates before tombstoning the
    // removed node. Readers may therefore observe a transient mixed-version
    // view across endpoints while removeNode is in flight; the operation only
    // guarantees logical consistency after it returns.
    //
    // Forward-degree decrements use the meta-only CAS helper
    // (`publishMetaFwdDeltaUpdated`) which does NOT require `fwd_claim` on the
    // predecessor — the 64-bit CAS on `published_meta` provides the atomicity
    // (RFC Phase 2 §concurrency note).
    const counts = publishUpdates(related.nodes.items);

    common.publishBothAdj(source_node, source_staging_adj, 0, 0);

    try retireRemoveNode(graph, source_adj_before);
    _ = graph.edge_count.fetchSub(@as(u64, @intCast(removed_visible_edge_count)), .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return .{
        .removed_visible_edges = @intCast(removed_visible_edge_count),
        .related_live_nodes_touched = @intCast(related.nodes.items.len),
        .left_repair_debt = counts.predecessors > 0 or counts.destinations > 0,
    };
}
