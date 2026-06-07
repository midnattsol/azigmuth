const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../maintenance/repair.zig");
const common = @import("common.zig");
const shared = @import("edge_shared.zig");

const ClonedGroupChain = struct {
    first_group: u32,
    last_group: u32,
    previous_to_last: ?u32,
};

fn prepareAppendBlockSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !shared.PreparedAppendBlock {
    if (side_adj.block_count == 0) {
        return .{ .new_block = try scratch.allocBlock(graph, side) };
    }

    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, side_adj)).?;
    const new_block = try scratch.allocBlock(graph, side);

    switch (side) {
        .fwd => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_idx, .fwd);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = tail_block.*;
            if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block).* = page_ops.edgeBlockFwdIdsAtConst(graph, tail_idx).*;
        },
        .rev => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_idx, .rev);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .rev).* = tail_block.*;
        },
    }

    return .{ .old_block = tail_idx, .new_block = new_block, .tail_index = tail_idx };
}

fn ensureTailCowGroupConstraintSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    if (prepared.old_block == null) return;
    if (side_adj.block_count <= 1) return;
    if (side_adj.group_count < constants.MAX_GROUPS_PER_NODE) return;

    const tail_idx = prepared.tail_index.?;
    var group_idx = side_adj.first_group;
    var visited_constraint: u16 = 0;
    while (group_idx != constants.END_OF_CHAIN) {
        if (group_idx >= graph.group_count) return error.CorruptGraph;
        if (visited_constraint >= side_adj.group_count or visited_constraint >= graph.group_count) return error.CorruptGraph;
        visited_constraint += 1;
        const group = page_ops.groupAtConst(graph, group_idx);
        if (tail_idx >= group.start and tail_idx < group.start + group.count) {
            if (group.count > 1) return error.RepairRequired;
            break;
        }
        group_idx = group.next;
    }
}

fn applyPreparedAppendSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !void {
    if (try tryApplyPreparedAppendSideFast(graph, side_adj, prepared, scratch)) return;

    if (@as(u22, side_adj.block_count) >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;

    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, side_adj.block_count + 1);
    defer block_list.deinit(graph.allocator);
    try common.collectBlockList(
        graph,
        side_adj.*,
        prepared.old_block,
        prepared.new_block,
        if (prepared.old_block == null) prepared.new_block else null,
        &block_list,
    );
    try common.buildSideFromBlocks(side_adj, graph, block_list.items, scratch);
}

fn cloneGroupChain(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    scratch: *common.MutationScratch,
) !ClonedGroupChain {
    try adjacency.validateSideAdjLayout(graph, side_adj.*);
    std.debug.assert(side_adj.group_count > 0);

    var group_idx = side_adj.first_group;
    var visited: u16 = 0;
    var first_group: ?u32 = null;
    var previous_group: ?u32 = null;
    var previous_to_last: ?u32 = null;
    var last_group: u32 = undefined;

    while (visited < side_adj.group_count) : (visited += 1) {
        const cloned_group_idx = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, cloned_group_idx).* = page_ops.groupAtConst(graph, group_idx).*;
        page_ops.groupAt(graph, cloned_group_idx).next = constants.END_OF_CHAIN;

        if (first_group == null) first_group = cloned_group_idx;
        if (previous_group) |previous| {
            page_ops.groupAt(graph, previous).next = cloned_group_idx;
            previous_to_last = previous;
        }

        previous_group = cloned_group_idx;
        last_group = cloned_group_idx;
        group_idx = page_ops.groupAtConst(graph, group_idx).next;
    }

    return .{
        .first_group = first_group.?,
        .last_group = last_group,
        .previous_to_last = if (side_adj.group_count > 1) previous_to_last else null,
    };
}

fn tryAppendNewBlockFast(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !bool {
    if (side_adj.group_count == 0) {
        if (prepared.new_block != side_adj.first_block + side_adj.block_count) return false;
        side_adj.block_count += 1;
        return true;
    }

    if (side_adj.block_count == 1) {
        const group = page_ops.groupAtConst(graph, side_adj.first_group);
        if (prepared.new_block == group.start + 1) {
            side_adj.first_block = group.start;
            side_adj.block_count = 2;
            side_adj.group_count = 0;
            side_adj.first_group = 0;
            return true;
        }
    }

    const cloned = try cloneGroupChain(graph, side_adj, scratch);
    const last_group = page_ops.groupAt(graph, cloned.last_group);
    side_adj.first_group = cloned.first_group;
    if (prepared.new_block == last_group.start + last_group.count) {
        last_group.count += 1;
        side_adj.block_count += 1;
        return true;
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return false;

    const tail_group_idx = try scratch.allocGroup(graph);
    page_ops.groupAt(graph, tail_group_idx).* = .{
        .start = prepared.new_block,
        .count = 1,
        .next = constants.END_OF_CHAIN,
    };
    last_group.next = tail_group_idx;
    side_adj.group_count += 1;
    side_adj.block_count += 1;
    return true;
}

fn tryReplaceTailBlockFast(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !bool {
    if (side_adj.group_count == 0) {
        if (side_adj.block_count == 1) {
            side_adj.first_block = prepared.new_block;
            return true;
        }

        const prefix_group_idx = try scratch.allocGroup(graph);
        const tail_group_idx = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, prefix_group_idx).* = .{
            .start = side_adj.first_block,
            .count = side_adj.block_count - 1,
            .next = tail_group_idx,
        };
        page_ops.groupAt(graph, tail_group_idx).* = .{
            .start = prepared.new_block,
            .count = 1,
            .next = constants.END_OF_CHAIN,
        };
        side_adj.first_group = prefix_group_idx;
        side_adj.group_count = 2;
        return true;
    }

    if (side_adj.block_count == 1) {
        side_adj.first_block = prepared.new_block;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return true;
    }

    const cloned = try cloneGroupChain(graph, side_adj, scratch);
    const last_group = page_ops.groupAt(graph, cloned.last_group);
    side_adj.first_group = cloned.first_group;
    if (last_group.count == 1) {
        last_group.start = prepared.new_block;
        return true;
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return false;

    const tail_group_idx = try scratch.allocGroup(graph);
    page_ops.groupAt(graph, tail_group_idx).* = .{
        .start = prepared.new_block,
        .count = 1,
        .next = constants.END_OF_CHAIN,
    };
    last_group.count -= 1;
    last_group.next = tail_group_idx;
    side_adj.group_count += 1;
    return true;
}

fn tryApplyPreparedAppendSideFast(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !bool {
    if (side_adj.block_count == 0) {
        side_adj.first_block = prepared.new_block;
        side_adj.block_count = 1;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return true;
    }

    if (@as(u22, side_adj.block_count) >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;

    if (prepared.old_block == null) return try tryAppendNewBlockFast(graph, side_adj, prepared, scratch);
    return try tryReplaceTailBlockFast(graph, side_adj, prepared, scratch);
}

fn insertForwardEdge(graph: *graph_core.GraphCore, block_idx: u32, destination: types.NodeId, relation: u16, flags: u16, edge_id: u32) !void {
    const forward_block = page_ops.edgeBlockAt(graph, block_idx, .fwd);
    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, block_idx) else undefined;
    const live = @popCount(forward_block.mask);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(live);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (forward_block.edges[probe].destination < destination.index) {
            insertion_point = probe + 1;
        } else if (forward_block.edges[probe].destination == destination.index) {
            if (!graph.multigraph_enabled) return error.EdgeAlreadyExists;
            if (graph.multigraph_enabled and id_block.ids[probe] < edge_id) {
                insertion_point = probe + 1;
            } else {
                search_end = probe;
            }
        } else {
            search_end = probe;
        }
    }
    var shift: u7 = @intCast(live);
    while (shift > insertion_point) {
        forward_block.edges[shift] = forward_block.edges[shift - 1];
        if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift - 1];
        shift -= 1;
    }
    forward_block.edges[insertion_point] = types.Edge{ .destination = destination.index, .relation = relation, .flags = @bitCast(flags) };
    if (graph.multigraph_enabled) id_block.ids[insertion_point] = edge_id;
    forward_block.mask = constants.denseMask(@intCast(live + 1));
}

fn insertReverseEdge(graph: *graph_core.GraphCore, block_idx: u32, source: types.NodeId) void {
    const reverse_block = page_ops.edgeBlockAt(graph, block_idx, .rev);
    const live = @popCount(reverse_block.mask);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(live);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (reverse_block.sources[probe] < source.index) {
            insertion_point = probe + 1;
        } else {
            search_end = probe;
        }
    }
    var shift: u7 = @intCast(live);
    while (shift > insertion_point) {
        reverse_block.sources[shift] = reverse_block.sources[shift - 1];
        shift -= 1;
    }
    reverse_block.sources[insertion_point] = source.index;
    reverse_block.mask = constants.denseMask(@intCast(live + 1));
}

fn addEdgeImpl(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
    relation: u16,
    flags: u16,
) !types.EdgeId {
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    const source_pub = endpoints.source_node.publishedFwdFromMeta(endpoints.source_meta);

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    endpoints.source_node.copyPublishedToStagingFwd(endpoints.source_meta);
    endpoints.destination_node.copyPublishedToStagingRev(endpoints.destination_meta);
    const source_staging = endpoints.source_node.stagingFwd(endpoints.source_meta);
    const destination_staging = endpoints.destination_node.stagingRev(endpoints.destination_meta);

    if (!graph.multigraph_enabled) {
        if (try adjacency.hasEdgeInSideAdjChecked(graph, source_pub, destination.index)) {
            return error.EdgeAlreadyExists;
        }
    }

    if (endpoints.source_meta.degree_fwd >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;
    if (endpoints.destination_meta.degree_rev >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const edge_id = if (graph.multigraph_enabled) try endpoints.source_node.nextEdgeId() else types.EdgeId{ .local = 0 };

    const forward_prepared = try prepareAppendBlockSide(graph, source_staging, .fwd, &scratch);
    const reverse_prepared = try prepareAppendBlockSide(graph, destination_staging, .rev, &scratch);

    try ensureTailCowGroupConstraintSide(graph, source_staging, forward_prepared);
    try ensureTailCowGroupConstraintSide(graph, destination_staging, reverse_prepared);

    const old_forward_groups = shared.OldGroupChain.captureSide(source_staging);
    const old_reverse_groups = shared.OldGroupChain.captureSide(destination_staging);

    try applyPreparedAppendSideTracked(graph, source_staging, forward_prepared, &scratch);
    try insertForwardEdge(graph, forward_prepared.new_block, destination, relation, flags, edge_id.local);
    var source_publish_adj = common.nodeAdjForSide(source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    try applyPreparedAppendSideTracked(graph, destination_staging, reverse_prepared, &scratch);
    insertReverseEdge(graph, reverse_prepared.new_block, source);
    var destination_publish_adj = common.nodeAdjForSide(destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    scratch.disarm();
    shared.publishAdded(&endpoints, source, destination, source_publish_adj, destination_publish_adj);
    try shared.retireAdded(graph, forward_prepared, reverse_prepared, old_forward_groups, old_reverse_groups);

    _ = graph.edge_count.fetchAdd(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return edge_id;
}

pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    _ = try addEdgeImpl(graph, source, destination, relation, flags);
}

pub fn addEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !types.EdgeId {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    return addEdgeImpl(graph, source, destination, relation, flags);
}
