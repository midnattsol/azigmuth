const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const rcu = @import("../../../concurrency/rcu.zig");
const repair = @import("../../../maintenance/repair.zig");
const node_validity = @import("../../../core/node_validity.zig");
const remove_types = @import("types.zig");

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
    scan: *const remove_types.RemovalScan,
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
        const destination_adj = node_access.publishedAdjAtConst(graph, .{ .index = destination_idx });
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
    scan: *const remove_types.RemovalScan,
) !void {
    const source_meta = node_access.loadPublishedMetaAtConst(graph, node);
    const source_degree_rev = node_access.publishedRevDegreeFromMetaAtConst(graph, node, source_meta);
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

            const source_fwd = node_access.publishedAdjAtConst(graph, .{ .index = source_idx });
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
            if (valid_count + self_count > source_degree_rev) return error.CorruptGraph;
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

            const source_fwd = node_access.publishedAdjAtConst(graph, .{ .index = source_idx });
            if (!(try adjacency.hasEdgeInAdjChecked(graph, source_fwd, node.index))) return error.CorruptGraph;

            valid_count += 1;
            if (valid_count + self_count > source_degree_rev) return error.CorruptGraph;
        }
    }

    if (valid_count + self_count != source_degree_rev) return error.CorruptGraph;
}

/// Validates the scanned node-removal neighborhood against the current graph state.
/// Returns error.CorruptGraph when the published views no longer match the scan.
pub fn validateNodeRemovalNeighborhood(
    graph: *graph_core.GraphCore,
    node: types.NodeId,
    scan: *const remove_types.RemovalScan,
) !void {
    try validateForwardDestinations(graph, scan.forward_destinations.items);
    try validateForwardView(graph, node, scan);
    try validateReverseView(graph, node, scan);
}
