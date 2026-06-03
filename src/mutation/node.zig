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
const node_validity = @import("../node_validity.zig");

const DestinationUpdate = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    published_adj_before: types.NodeAdj,
    staging_adj_after: types.NodeAdj,
    new_degree_rev: u16,
    decrement_visible_fwd: bool,
    needs_reverse_retire: bool = false,
};

const RelatedNode = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    claims: common.ClaimedNodeSides,
    needs_reverse_cleanup: bool = false,
    needs_visible_fwd_decrement: bool = false,
};

const ScratchAllocations = struct {
    reverse_blocks: std.ArrayList(u32) = .empty,
    groups: std.ArrayList(u32) = .empty,
    active: bool = true,

    fn allocReverseBlock(self: *ScratchAllocations, graph: *graph_core.GraphCore) !u32 {
        const block_index = try page_ops.allocBlock(graph, .rev);
        self.reverse_blocks.append(graph.allocator, block_index) catch |err| {
            page_ops.freeBlock(graph, block_index, .rev);
            return err;
        };
        return block_index;
    }

    fn allocGroup(self: *ScratchAllocations, graph: *graph_core.GraphCore) !u32 {
        const group_index = try page_ops.allocGroup(graph);
        self.groups.append(graph.allocator, group_index) catch |err| {
            page_ops.freeGroup(graph, group_index);
            return err;
        };
        return group_index;
    }

    fn disarm(self: *ScratchAllocations) void {
        self.active = false;
    }

    fn adoptReverseBlocks(self: *ScratchAllocations, allocator: std.mem.Allocator, blocks: []const u32) !void {
        try self.reverse_blocks.appendSlice(allocator, blocks);
    }

    fn cleanup(self: *ScratchAllocations, graph: *graph_core.GraphCore) void {
        if (!self.active) return;

        var block_count = self.reverse_blocks.items.len;
        while (block_count > 0) {
            block_count -= 1;
            page_ops.freeBlock(graph, self.reverse_blocks.items[block_count], .rev);
        }

        var group_count = self.groups.items.len;
        while (group_count > 0) {
            group_count -= 1;
            page_ops.freeGroup(graph, self.groups.items[group_count]);
        }
    }

    fn deinit(self: *ScratchAllocations, allocator: std.mem.Allocator) void {
        self.reverse_blocks.deinit(allocator);
        self.groups.deinit(allocator);
    }
};

fn toCachedDegree(count: usize) u16 {
    return if (count < constants.DEGREE_OVERFLOW) @intCast(count) else constants.DEGREE_OVERFLOW;
}

fn publishBothAdj(node: *types.NodeBuffer, adj: types.NodeAdj) void {
    const meta = node.loadPublishedMeta();
    node.stagingFwd(meta).* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = common.publishStagedBoth(node, meta, adj.flags);
}

fn publishRevAdj(node: *types.NodeBuffer, adj: types.NodeAdj) void {
    const meta = node.loadPublishedMeta();
    node.stagingRev(meta).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    _ = common.publishStagedRev(node, meta, adj.flags);
}

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
    var visited: u16 = 0;
    while (visited < published_adj.group_count_fwd) : (visited += 1) {
        if (group_index == constants.END_OF_CHAIN) break;
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

fn retireAdjacencySide(
    graph: *graph_core.GraphCore,
    published_adj: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const first_block: u32 = if (side == .fwd) published_adj.first_block_fwd else published_adj.first_block_rev;
    const block_count: u16 = if (side == .fwd) published_adj.block_count_fwd else published_adj.block_count_rev;
    const group_count: u16 = if (side == .fwd) published_adj.group_count_fwd else published_adj.group_count_rev;
    const first_group: u32 = if (side == .fwd) published_adj.first_group_fwd else published_adj.first_group_rev;

    if (block_count == 0) return;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(graph, @intCast(block_idx)),
                .rev => try rcu.retireBlockRev(graph, @intCast(block_idx)),
            }
        }
        return;
    }

    var group_idx = first_group;
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(graph, @intCast(block_idx)),
                .rev => try rcu.retireBlockRev(graph, @intCast(block_idx)),
            }
        }
        const old_group = group_idx;
        group_idx = group.next;
        rcu.retireGroup(graph, old_group);
    }
}

fn flushReverseRun(
    graph: *graph_core.GraphCore,
    scratch: *ScratchAllocations,
    staging_adj: *types.NodeAdj,
    run_start: *u32,
    run_count: *u16,
    total_blocks: *u16,
    first_block_set: *bool,
    tail_group: *?u32,
) !void {
    if (run_count.* == 0) return;

    if (!first_block_set.*) {
        staging_adj.first_block_rev = run_start.*;
        staging_adj.block_count_rev = run_count.*;
        first_block_set.* = true;
    } else if (tail_group.* == null and staging_adj.group_count_rev == 0) {
        const prefix_group = try scratch.allocGroup(graph);
        const group = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, prefix_group).* = .{
            .start = staging_adj.first_block_rev,
            .count = staging_adj.block_count_rev,
            .next = group,
        };
        page_ops.groupAt(graph, group).* = .{
            .start = run_start.*,
            .count = run_count.*,
            .next = constants.END_OF_CHAIN,
        };
        staging_adj.first_group_rev = prefix_group;
        staging_adj.group_count_rev = 2;
        tail_group.* = group;
    } else {
        const group = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, group).* = .{
            .start = run_start.*,
            .count = run_count.*,
            .next = constants.END_OF_CHAIN,
        };
        page_ops.groupAt(graph, tail_group.*.?).next = group;
        tail_group.* = group;
        staging_adj.group_count_rev += 1;
    }

    total_blocks.* += run_count.*;
    run_count.* = 0;
}

fn buildReverseAdjacencyFromBlocksTracked(
    staging_adj: *types.NodeAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *ScratchAllocations,
) !void {
    staging_adj.first_block_rev = 0;
    staging_adj.block_count_rev = 0;
    staging_adj.group_count_rev = 0;
    staging_adj.first_group_rev = 0;
    if (blocks.len == 0) return;

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set = false;
    var tail_group: ?u32 = null;

    for (blocks) |block_index| {
        if (run_count > 0 and block_index == run_start + run_count) {
            run_count += 1;
        } else {
            if (run_count > 0) {
                try flushReverseRun(graph, scratch, staging_adj, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
            }
            run_start = block_index;
            run_count = 1;
        }
    }

    if (run_count > 0) {
        try flushReverseRun(graph, scratch, staging_adj, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
    }

    staging_adj.block_count_rev = total_blocks;
}

fn collectReverseSources(graph: *const graph_core.GraphCore, node: types.NodeId, sources: *std.ArrayList(u32)) !void {
    const published_adj = page_ops.nodeAtConst(graph, node).publishedAdj();
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

fn markRelatedNode(
    graph: *graph_core.GraphCore,
    related_nodes: *std.ArrayList(RelatedNode),
    node_index: u32,
    mark_reverse_cleanup: bool,
    mark_visible_fwd_decrement: bool,
) !void {
    for (related_nodes.items) |*entry| {
        if (entry.node_index != node_index) continue;
        if (mark_reverse_cleanup) try entry.claims.ensureRev();
        if (mark_visible_fwd_decrement) try entry.claims.ensureFwd();
        entry.needs_reverse_cleanup = entry.needs_reverse_cleanup or mark_reverse_cleanup;
        entry.needs_visible_fwd_decrement = entry.needs_visible_fwd_decrement or mark_visible_fwd_decrement;
        return;
    }

    const node_buffer = page_ops.nodeAt(graph, .{ .index = node_index });
    const claims = try common.tryClaimNodeSides(node_buffer, mark_visible_fwd_decrement, mark_reverse_cleanup);
    try related_nodes.append(graph.allocator, .{
        .node_index = node_index,
        .node_buffer = node_buffer,
        .claims = claims,
        .needs_reverse_cleanup = mark_reverse_cleanup,
        .needs_visible_fwd_decrement = mark_visible_fwd_decrement,
    });
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

pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, node);
    var source_claims = try common.tryClaimNodeSides(source_node, true, true);
    defer source_claims.release();

    const source_adj_before = source_node.publishedAdj();
    if (!node_validity.snapshotIsLive(source_adj_before)) return error.InvalidNode;

    var forward_destinations: std.ArrayList(u32) = .empty;
    defer forward_destinations.deinit(graph.allocator);
    try collectForwardDestinations(graph, node, &forward_destinations);

    var reverse_sources: std.ArrayList(u32) = .empty;
    defer reverse_sources.deinit(graph.allocator);
    try collectReverseSources(graph, node, &reverse_sources);

    const had_self_edge = for (forward_destinations.items) |destination_index| {
        if (destination_index == node.index) break true;
    } else false;
    const removed_visible_edge_count = countVisibleForwardEdges(graph, forward_destinations.items) + countVisibleIncomingEdgesExcludingSelf(graph, source_adj_before, node.index);

    var related_nodes: std.ArrayList(RelatedNode) = .empty;
    defer {
        var remaining = related_nodes.items.len;
        while (remaining > 0) {
            remaining -= 1;
            related_nodes.items[remaining].claims.release();
        }
        related_nodes.deinit(graph.allocator);
    }

    for (forward_destinations.items) |destination_index| {
        if (destination_index == node.index) continue;
        try markRelatedNode(graph, &related_nodes, destination_index, true, false);
    }
    for (reverse_sources.items) |source_index| {
        if (source_index == node.index) continue;
        if (!node_validity.isNodeLiveIndex(graph, source_index)) continue;
        try markRelatedNode(graph, &related_nodes, source_index, false, true);
    }

    var scratch = ScratchAllocations{};
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

            scratch.adoptReverseBlocks(graph.allocator, rb.new_blocks.items) catch |err| {
                for (rb.new_blocks.items) |bid| page_ops.freeBlock(graph, bid, .rev);
                return err;
            };

            var destination_staging_adj = destination_adj_before;
            try buildReverseAdjacencyFromBlocksTracked(&destination_staging_adj, graph, rb.new_blocks.items, &scratch);
            const live_after: usize = rb.live_after;
            repair.updateRepairDebt(graph, &destination_staging_adj, related.node_index, .rev);

            try destination_updates.append(graph.allocator, .{
                .node_index = related.node_index,
                .node_buffer = related.node_buffer,
                .published_adj_before = destination_adj_before,
                .staging_adj_after = destination_staging_adj,
                .new_degree_rev = toCachedDegree(live_after),
                .decrement_visible_fwd = related.needs_visible_fwd_decrement,
                .needs_reverse_retire = true,
            });
        } else if (related.needs_visible_fwd_decrement) {
            try destination_updates.append(graph.allocator, .{
                .node_index = related.node_index,
                .node_buffer = related.node_buffer,
                .published_adj_before = related.node_buffer.publishedAdj(),
                .staging_adj_after = related.node_buffer.publishedAdj(),
                .new_degree_rev = related.node_buffer.degree_rev,
                .decrement_visible_fwd = true,
            });
        }
    }

    var source_staging_adj = source_adj_before;
    if (had_self_edge) {
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

        scratch.adoptReverseBlocks(graph.allocator, rb.new_blocks.items) catch |err| {
            for (rb.new_blocks.items) |bid| page_ops.freeBlock(graph, bid, .rev);
            return err;
        };
        try buildReverseAdjacencyFromBlocksTracked(&source_staging_adj, graph, rb.new_blocks.items, &scratch);
    }

    source_staging_adj.first_block_fwd = 0;
    source_staging_adj.block_count_fwd = 0;
    source_staging_adj.group_count_fwd = 0;
    source_staging_adj.first_group_fwd = 0;
    source_staging_adj.flags.removed = true;
    source_staging_adj.flags.needs_repair_fwd = false;
    source_staging_adj.flags.needs_repair_rev = false;
    source_node.degree_fwd = 0;
    source_node.degree_rev = 0;

    for (destination_updates.items) |update| {
        if (update.decrement_visible_fwd) {
            common.decrementDegree(&update.node_buffer.degree_fwd);
        }
        if (update.needs_reverse_retire) {
            update.node_buffer.degree_rev = update.new_degree_rev;
            publishRevAdj(update.node_buffer, update.staging_adj_after);
        }
    }

    publishBothAdj(source_node, source_staging_adj);

    // With the target node now marked removed, recompute forward repair debt
    // on each live predecessor.  Their forward adjacency still contains a
    // tombstoned reference that needs compaction, and the flag makes it
    // immediately discoverable by repairBudgeted.
    // Also recover exact degree cache if it was previously saturated.
    for (destination_updates.items) |update| {
        if (update.decrement_visible_fwd) {
            repair.updateRepairDebtSide(graph, update.node_buffer, update.node_index, .fwd);
            common.recomputeDegreeIfOverflow(graph, &update.node_buffer.degree_fwd, update.node_index, .fwd);
        }
    }

    for (destination_updates.items) |update| {
        if (update.needs_reverse_retire) {
            try retireAdjacencySide(graph, update.published_adj_before, .rev);
        }
    }
    try retireAdjacencySide(graph, source_adj_before, .fwd);
    if (had_self_edge) {
        try retireAdjacencySide(graph, source_adj_before, .rev);
    }

    scratch.disarm();
    _ = graph.edge_count.fetchSub(@as(u64, @intCast(removed_visible_edge_count)), .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);
}
