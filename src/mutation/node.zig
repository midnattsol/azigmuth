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
};

const RelatedNode = struct {
    node_index: u32,
    node_buffer: *types.NodeBuffer,
    claims: common.ClaimedAdjacencies,
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

    var gidx = first_group;
    while (gidx != constants.END_OF_CHAIN) {
        const grp = page_ops.groupAtConst(graph, gidx);
        for (grp.start..grp.start + grp.count) |block_idx| {
            switch (side) {
                .fwd => try rcu.retireBlockFwd(graph, @intCast(block_idx)),
                .rev => try rcu.retireBlockRev(graph, @intCast(block_idx)),
            }
        }
        const old_group = gidx;
        gidx = grp.next;
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

fn rebuildReverseWithoutSourceInStaging(
    graph: *graph_core.GraphCore,
    scratch: *ScratchAllocations,
    staging_adj: *types.NodeAdj,
    published_adj: types.NodeAdj,
    source_index: u32,
) !usize {
    var live_after: usize = 0;
    var removed_matches: usize = 0;

    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) {
                    removed_matches += 1;
                } else {
                    live_after += 1;
                }
            }
        }
    } else {
        var gidx = published_adj.first_group_rev;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) {
                        removed_matches += 1;
                    } else {
                        live_after += 1;
                    }
                }
            }
            gidx = grp.next;
        }
    }

    if (removed_matches != 1) return error.CorruptGraph;

    var new_blocks = try std.ArrayList(u32).initCapacity(graph.allocator, (live_after + 63) / 64);
    defer new_blocks.deinit(graph.allocator);

    var current_block: ?u32 = null;
    var current_live: u7 = 0;

    if (published_adj.group_count_rev == 0) {
        for (published_adj.first_block_rev..published_adj.first_block_rev + published_adj.block_count_rev) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                if (block.sources[slot] == source_index) continue;
                if (current_block == null or current_live == 64) {
                    current_block = try scratch.allocReverseBlock(graph);
                    try new_blocks.append(graph.allocator, current_block.?);
                    current_live = 0;
                }
                const destination_block = page_ops.edgeBlockAt(graph, current_block.?, .rev);
                destination_block.sources[current_live] = block.sources[slot];
                destination_block.mask = constants.denseMask(current_live + 1);
                current_live += 1;
            }
        }
    } else {
        var gidx = published_adj.first_group_rev;
        while (gidx != constants.END_OF_CHAIN) {
            const grp = page_ops.groupAtConst(graph, gidx);
            for (grp.start..grp.start + grp.count) |block_idx| {
                const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    if (block.sources[slot] == source_index) continue;
                    if (current_block == null or current_live == 64) {
                        current_block = try scratch.allocReverseBlock(graph);
                        try new_blocks.append(graph.allocator, current_block.?);
                        current_live = 0;
                    }
                    const destination_block = page_ops.edgeBlockAt(graph, current_block.?, .rev);
                    destination_block.sources[current_live] = block.sources[slot];
                    destination_block.mask = constants.denseMask(current_live + 1);
                    current_live += 1;
                }
            }
            gidx = grp.next;
        }
    }

    try buildReverseAdjacencyFromBlocksTracked(staging_adj, graph, new_blocks.items, scratch);
    return live_after;
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

    var gidx = published_adj.first_group_rev;
    while (gidx != constants.END_OF_CHAIN) {
        const grp = page_ops.groupAtConst(graph, gidx);
        for (grp.start..grp.start + grp.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                try sources.append(graph.allocator, block.sources[slot]);
            }
        }
        gidx = grp.next;
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
        entry.needs_reverse_cleanup = entry.needs_reverse_cleanup or mark_reverse_cleanup;
        entry.needs_visible_fwd_decrement = entry.needs_visible_fwd_decrement or mark_visible_fwd_decrement;
        return;
    }

    const node_buffer = page_ops.nodeAt(graph, .{ .index = node_index });
    const claims = try common.tryClaimAdjacencies(node_buffer, node_buffer, node_index, node_index);
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

    var gidx = published_adj.first_group_rev;
    while (gidx != constants.END_OF_CHAIN) {
        const grp = page_ops.groupAtConst(graph, gidx);
        for (grp.start..grp.start + grp.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .rev);
            const live = @popCount(block.mask);
            for (0..live) |slot| {
                const source_index = block.sources[slot];
                if (source_index == self_index) continue;
                if (node_validity.isNodeLiveIndex(graph, source_index)) total += 1;
            }
        }
        gidx = grp.next;
    }
    return total;
}

pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, node);
    var source_claims = try common.tryClaimAdjacencies(source_node, source_node, node.index, node.index);
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

            related.node_buffer.copyPublishedToStaging();
            const destination_staging_adj = related.node_buffer.stagingAdj();
            const live_after = try rebuildReverseWithoutSourceInStaging(
                graph,
                &scratch,
                destination_staging_adj,
                destination_adj_before,
                node.index,
            );
            repair.updateRepairDebt(graph, destination_staging_adj, related.node_index, .rev);
            related.node_buffer.degree_rev = toCachedDegree(live_after);

            try destination_updates.append(graph.allocator, .{
                .node_index = related.node_index,
                .node_buffer = related.node_buffer,
                .published_adj_before = destination_adj_before,
            });
        }

        if (related.needs_visible_fwd_decrement) {
            common.decrementDegree(&related.node_buffer.degree_fwd);
        }
    }

    source_node.copyPublishedToStaging();
    const source_staging_adj = source_node.stagingAdj();
    if (had_self_edge) {
        _ = try rebuildReverseWithoutSourceInStaging(
            graph,
            &scratch,
            source_staging_adj,
            source_adj_before,
            node.index,
        );
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
        update.node_buffer.publishStagingAdj();
    }
    source_node.publishStagingAdj();

    for (destination_updates.items) |update| {
        _ = update.node_index;
        try retireAdjacencySide(graph, update.published_adj_before, .rev);
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
