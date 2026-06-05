//! Edge insertion and removal — mutable edge operations built on the shared
//! RCU + COW mutation machinery with per-side publication.

const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../maintenance/repair.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");
const std = @import("std");

const PreparedAppendBlock = struct {
    old_block: ?u32 = null,
    new_block: u32,
    tail_index: ?u32 = null,
};

const OldGroupChain = struct {
    first_group: ?u32 = null,
    group_count: u16 = 0,

    fn captureSide(side_adj: *const types.SideAdj) OldGroupChain {
        return .{
            .first_group = if (side_adj.group_count > 0) side_adj.first_group else null,
            .group_count = side_adj.group_count,
        };
    }

    fn retire(self: OldGroupChain, graph: *graph_core.GraphCore) void {
        if (self.first_group) |first_group| {
            common.retireGroupChain(graph, first_group, self.group_count);
        }
    }
};

const RemovalPlan = struct {
    found: common.AdjSlot,
    live_before: u7,
};

const RemovalBuild = struct {
    old_block: u32,
    new_block: u32,
    new_live: u7,
};

const SideRewriteResult = struct {
    old_block: ?u32 = null,
    new_block: u32,
    new_live: u7 = 0,
    degree_after: u22,
};

fn nodeAdjForSide(side_adj: types.SideAdj, flags: types.NodeFlags, comptime side: adjacency.AdjSide) types.NodeAdj {
    var adj = std.mem.zeroes(types.NodeAdj);
    adj.flags = flags;
    switch (side) {
        .fwd => {
            adj.first_block_fwd = side_adj.first_block;
            adj.block_count_fwd = side_adj.block_count;
            adj.group_count_fwd = side_adj.group_count;
            adj.first_group_fwd = side_adj.first_group;
        },
        .rev => {
            adj.first_block_rev = side_adj.first_block;
            adj.block_count_rev = side_adj.block_count;
            adj.group_count_rev = side_adj.group_count;
            adj.first_group_rev = side_adj.first_group;
        },
    }
    return adj;
}

fn prepareAppendBlockSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !PreparedAppendBlock {
    if (side_adj.block_count == 0) {
        return .{ .new_block = try scratch.allocBlock(graph, side) };
    }

    const tail_index = adjacency.tailBlockIndexSide(graph, side_adj).?;
    const new_block = try scratch.allocBlock(graph, side);

    switch (side) {
        .fwd => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_index, .fwd);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_index };
            }
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = tail_block.*;
            page_ops.edgeBlockFwdIdsAt(graph, new_block).* = page_ops.edgeBlockFwdIdsAtConst(graph, tail_index).*;
        },
        .rev => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_index, .rev);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_index };
            }
            page_ops.edgeBlockAt(graph, new_block, .rev).* = tail_block.*;
        },
    }

    return .{ .old_block = tail_index, .new_block = new_block, .tail_index = tail_index };
}

fn ensureTailCowGroupConstraintSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: PreparedAppendBlock,
) !void {
    if (prepared.old_block == null) return;
    if (side_adj.block_count <= 1) return;
    if (side_adj.group_count < constants.MAX_GROUPS_PER_NODE) return;

    const tail_index = prepared.tail_index.?;
    var group_index = side_adj.first_group;
    var visited_constraint: u16 = 0;
    while (group_index != constants.END_OF_CHAIN) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (visited_constraint >= side_adj.group_count or visited_constraint >= graph.group_count) return error.CorruptGraph;
        visited_constraint += 1;
        const group = page_ops.groupAtConst(graph, group_index);
        if (tail_index >= group.start and tail_index < group.start + group.count) {
            if (group.count > 1) return error.RepairRequired;
            break;
        }
        group_index = group.next;
    }
}

fn applyPreparedAppendSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: PreparedAppendBlock,
    scratch: *common.MutationScratch,
) !void {
    if (side_adj.block_count == 0) {
        side_adj.first_block = prepared.new_block;
        side_adj.block_count = 1;
        return;
    }

    if (@as(u22, side_adj.block_count) >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;

    var block_list: std.ArrayList(u32) = .empty;
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

fn insertForwardEdge(graph: *graph_core.GraphCore, block_index: u32, destination: types.NodeId, relation: u16, flags: u16, edge_id: u32) !void {
    const forward_block = page_ops.edgeBlockAt(graph, block_index, .fwd);
    const id_block = page_ops.edgeBlockFwdIdsAt(graph, block_index);
    const live = @popCount(forward_block.mask);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(live);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (forward_block.edges[probe].destination < destination.index) {
            insertion_point = probe + 1;
        } else if (forward_block.edges[probe].destination == destination.index) {
            if (!graph.multigraph_enabled) return error.EdgeAlreadyExists;
            // Multigraph: resolve by edge_id order (unique per source)
            if (id_block.ids[probe] < edge_id) {
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
        id_block.ids[shift] = id_block.ids[shift - 1];
        shift -= 1;
    }
    forward_block.edges[insertion_point] = types.Edge{ .destination = destination.index, .relation = relation, .flags = @bitCast(flags) };
    id_block.ids[insertion_point] = edge_id;
    forward_block.mask = constants.denseMask(@intCast(live + 1));
}

fn insertReverseEdge(graph: *graph_core.GraphCore, block_index: u32, source: types.NodeId) void {
    const reverse_block = page_ops.edgeBlockAt(graph, block_index, .rev);
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

fn planRemovalSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    found: common.AdjSlot,
    comptime side: adjacency.AdjSide,
) !RemovalPlan {
    const live_before: u7 = switch (side) {
        .fwd => @intCast(@popCount(page_ops.edgeBlockAtConst(graph, found.block_idx, .fwd).mask)),
        .rev => @intCast(@popCount(page_ops.edgeBlockAtConst(graph, found.block_idx, .rev).mask)),
    };
    const new_live: u7 = live_before - 1;
    const tail_index = adjacency.tailBlockIndexSide(graph, side_adj) orelse return error.CorruptGraph;
    const is_tail = found.block_idx == tail_index;
    if (!is_tail and new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;
    return .{ .found = found, .live_before = live_before };
}

fn applyRemovalPlanSide(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    plan: RemovalPlan,
    comptime side: adjacency.AdjSide,
    allocs: *common.MutationScratch,
) !RemovalBuild {
    const old_block = plan.found.block_idx;
    const new_block = try allocs.allocBlock(graph, side);
    if (new_block == old_block) return error.CorruptGraph;
    const new_live: u7 = plan.live_before - 1;

    switch (side) {
        .fwd => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .fwd);
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = block_before.*;
            const ids_before = page_ops.edgeBlockFwdIdsAtConst(graph, old_block);
            page_ops.edgeBlockFwdIdsAt(graph, new_block).* = ids_before.*;
            const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
            const id_block = page_ops.edgeBlockFwdIdsAt(graph, new_block);
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) {
                block.edges[shift] = block.edges[shift + 1];
                id_block.ids[shift] = id_block.ids[shift + 1];
            }
            block.mask = constants.denseMask(@intCast(new_live));
        },
        .rev => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .rev);
            page_ops.edgeBlockAt(graph, new_block, .rev).* = block_before.*;
            const block = page_ops.edgeBlockAt(graph, new_block, .rev);
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) block.sources[shift] = block.sources[shift + 1];
            block.mask = constants.denseMask(@intCast(new_live));
        },
    }

    var block_list: std.ArrayList(u32) = .empty;
    defer block_list.deinit(graph.allocator);
    try common.collectBlockList(
        graph,
        published_side.*,
        old_block,
        if (new_live > 0) new_block else null,
        null,
        &block_list,
    );
    try common.buildSideFromBlocks(staging_side, graph, block_list.items, allocs);

    return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
}

fn addEdgeImpl(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
    relation: u16,
    flags: u16,
) !types.EdgeId {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    const source_meta = source_node.loadPublishedMeta();
    const destination_meta = destination_node.loadPublishedMeta();
    const source_pub = source_node.publishedFwdFromMeta(source_meta);
    const source_flags = source_meta.flags();
    const destination_flags = destination_meta.flags();
    if (source_meta.removed or destination_meta.removed) {
        return error.InvalidNode;
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    source_node.copyPublishedToStagingFwd(source_meta);
    destination_node.copyPublishedToStagingRev(destination_meta);
    const sfwd = source_node.stagingFwd(source_meta);
    const srev = destination_node.stagingRev(destination_meta);

    if (!graph.multigraph_enabled) {
        if (adjacency.hasEdgeInSideAdj(graph, source_pub, destination.index)) {
            return error.EdgeAlreadyExists;
        }
    }

    if (source_meta.degree_fwd >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;
    if (destination_meta.degree_rev >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const edge_id = source_node.nextEdgeId();

    const forward_prepared = try prepareAppendBlockSide(graph, sfwd, .fwd, &scratch);
    const reverse_prepared = try prepareAppendBlockSide(graph, srev, .rev, &scratch);

    try ensureTailCowGroupConstraintSide(graph, sfwd, forward_prepared);
    try ensureTailCowGroupConstraintSide(graph, srev, reverse_prepared);

    const old_forward_groups = OldGroupChain.captureSide(sfwd);
    const old_reverse_groups = OldGroupChain.captureSide(srev);

    try applyPreparedAppendSideTracked(graph, sfwd, forward_prepared, &scratch);
    try insertForwardEdge(graph, forward_prepared.new_block, destination, relation, flags, edge_id.local);
    var source_publish_adj = nodeAdjForSide(sfwd.*, source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    try applyPreparedAppendSideTracked(graph, srev, reverse_prepared, &scratch);
    insertReverseEdge(graph, reverse_prepared.new_block, source);
    var destination_publish_adj = nodeAdjForSide(srev.*, destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    scratch.disarm();

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(source_meta)) == @as(u64, @bitCast(destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(source_node, source_meta, merged_flags, 1, 1);
    } else {
        // publish reverse first, then forward (RFC §5.2)
        _ = common.publishStagedRev(destination_node, destination_meta, destination_publish_adj.flags.needs_repair_rev, 1);
        _ = common.publishStagedFwd(source_node, source_meta, source_publish_adj.flags.needs_repair_fwd, 1);
    }

    if (forward_prepared.old_block) |old_block| try rcu.retireBlockFwd(graph, old_block);
    if (reverse_prepared.old_block) |old_block| try rcu.retireBlockRev(graph, old_block);
    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchAdd(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return edge_id;
}

/// Adds a directed edge `source → destination` with a relation label and flags.
pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    _ = try addEdgeImpl(graph, source, destination, relation, flags);
}

/// Adds a directed edge and returns its unique EdgeId.
pub fn addEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !types.EdgeId {
    return addEdgeImpl(graph, source, destination, relation, flags);
}

/// Removes the directed edge `source → destination` if it exists, returning `true`.
pub fn removeEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId) !bool {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    const source_meta = source_node.loadPublishedMeta();
    const destination_meta = destination_node.loadPublishedMeta();
    const source_flags = source_meta.flags();
    const destination_flags = destination_meta.flags();
    if (source_meta.removed or destination_meta.removed) {
        return error.InvalidNode;
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_pubfwd = source_node.publishedFwdFromMeta(source_meta);
    const dest_pubrev = destination_node.publishedRevFromMeta(destination_meta);

    const old_forward_groups = OldGroupChain.captureSide(&source_pubfwd);
    const old_reverse_groups = OldGroupChain.captureSide(&dest_pubrev);

    if (graph.multigraph_enabled) {
        const match_count = adjacency.countForwardDestinationMatches(
            graph, source_pubfwd.first_block, source_pubfwd.block_count,
            source_pubfwd.group_count, source_pubfwd.first_group,
            destination.index,
        );
        if (match_count == 0) return false;
        if (match_count > 1) {
            source_node.copyPublishedToStagingFwd(source_meta);
            destination_node.copyPublishedToStagingRev(destination_meta);
            const sfwd2 = source_node.stagingFwd(source_meta);
            const srev2 = destination_node.stagingRev(destination_meta);
            var bulk_scratch = common.MutationScratch{};
            defer bulk_scratch.deinit(graph.allocator);
            defer bulk_scratch.cleanup(graph);
            const fwd_result = try rebuildForwardRemoveAll(graph, &source_pubfwd, destination.index, &bulk_scratch);
            sfwd2.* = fwd_result.new_side;
            const rev_result = try rebuildReverseRemoveCount(graph, &dest_pubrev, source.index, match_count, &bulk_scratch);
            srev2.* = rev_result;
            var source_adj = nodeAdjForSide(sfwd2.*, source_flags, .fwd);
            repair.updateRepairDebt(graph, &source_adj, source.index, .fwd);
            var dest_adj = nodeAdjForSide(srev2.*, destination_flags, .rev);
            repair.updateRepairDebt(graph, &dest_adj, destination.index, .rev);
            bulk_scratch.disarm();
            if (source.index == destination.index) {
                var merged = source_adj.flags;
                merged.needs_repair_rev = dest_adj.flags.needs_repair_rev;
                merged.removed = false;
                _ = common.publishBothDelta(source_node, source_meta, merged, -@as(i23, @intCast(match_count)), -@as(i23, @intCast(match_count)));
            } else {
                _ = common.publishStagedRev(destination_node, destination_meta, dest_adj.flags.needs_repair_rev, -@as(i23, @intCast(match_count)));
                _ = common.publishStagedFwd(source_node, source_meta, source_adj.flags.needs_repair_fwd, -@as(i23, @intCast(match_count)));
            }
            try common.retireSide(graph, nodeAdjForSide(source_pubfwd, source_flags, .fwd), .fwd);
            try common.retireSide(graph, nodeAdjForSide(dest_pubrev, destination_flags, .rev), .rev);
            old_forward_groups.retire(graph);
            old_reverse_groups.retire(graph);
            _ = graph.edge_count.fetchSub(match_count, .release);
            rcu.bumpEpoch(graph);
            writer_guard.end();
            rcu.reclaimRetired(graph);
            return true;
        }
    }

    const forward_found = common.findSlotInAdj(
        graph,
        source_pubfwd.first_block,
        source_pubfwd.block_count,
        source_pubfwd.group_count,
        source_pubfwd.first_group,
        destination.index,
        .fwd,
    ) orelse return false;

    const reverse_found = common.findSlotInAdj(
        graph,
        dest_pubrev.first_block,
        dest_pubrev.block_count,
        dest_pubrev.group_count,
        dest_pubrev.first_group,
        source.index,
        .rev,
    ) orelse return error.CorruptGraph;

    const forward_plan = try planRemovalSide(graph, &source_pubfwd, forward_found, .fwd);
    const reverse_plan = try planRemovalSide(graph, &dest_pubrev, reverse_found, .rev);

    source_node.copyPublishedToStagingFwd(source_meta);
    destination_node.copyPublishedToStagingRev(destination_meta);
    const sfwd = source_node.stagingFwd(source_meta);
    const srev = destination_node.stagingRev(destination_meta);

    var allocs = common.MutationScratch{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const forward_build = try applyRemovalPlanSide(graph, sfwd, &source_pubfwd, forward_plan, .fwd, &allocs);
    const reverse_build = try applyRemovalPlanSide(graph, srev, &dest_pubrev, reverse_plan, .rev, &allocs);
    var source_publish_adj = nodeAdjForSide(sfwd.*, source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    var destination_publish_adj = nodeAdjForSide(srev.*, destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    allocs.disarm();

    if (source_meta.degree_fwd == 0) return error.CorruptGraph;
    if (destination_meta.degree_rev == 0) return error.CorruptGraph;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(source_meta)) == @as(u64, @bitCast(destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(source_node, source_meta, merged_flags, -1, -1);
    } else {
        // publish reverse first, then forward (RFC §5.2)
        _ = common.publishStagedRev(destination_node, destination_meta, destination_publish_adj.flags.needs_repair_rev, -1);
        _ = common.publishStagedFwd(source_node, source_meta, source_publish_adj.flags.needs_repair_fwd, -1);
    }

    try rcu.retireBlockFwd(graph, forward_build.old_block);
    try rcu.retireBlockRev(graph, reverse_build.old_block);
    if (forward_build.new_live == 0) try rcu.retireBlockFwd(graph, forward_build.new_block);
    if (reverse_build.new_live == 0) try rcu.retireBlockRev(graph, reverse_build.new_block);

    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchSub(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return true;
}

/// Removes a specific edge identified by its EdgeId. Returns true if found and removed.
pub fn removeEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, edge_id: types.EdgeId) !bool {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    const source_meta = source_node.loadPublishedMeta();
    const destination_meta = destination_node.loadPublishedMeta();
    const source_flags = source_meta.flags();
    const destination_flags = destination_meta.flags();
    if (source_meta.removed or destination_meta.removed) {
        return error.InvalidNode;
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_pubfwd = source_node.publishedFwdFromMeta(source_meta);
    const dest_pubrev = destination_node.publishedRevFromMeta(destination_meta);

    const old_forward_groups = OldGroupChain.captureSide(&source_pubfwd);
    const old_reverse_groups = OldGroupChain.captureSide(&dest_pubrev);

    const forward_found = common.findSlotInAdjById(
        graph, source_pubfwd.first_block, source_pubfwd.block_count,
        source_pubfwd.group_count, source_pubfwd.first_group,
        destination.index, edge_id.local,
    ) orelse return false;

    const reverse_found = common.findSlotInAdj(
        graph, dest_pubrev.first_block, dest_pubrev.block_count,
        dest_pubrev.group_count, dest_pubrev.first_group,
        source.index, .rev,
    ) orelse return error.CorruptGraph;

    const forward_plan = try planRemovalSide(graph, &source_pubfwd, forward_found, .fwd);
    const reverse_plan = try planRemovalSide(graph, &dest_pubrev, reverse_found, .rev);

    source_node.copyPublishedToStagingFwd(source_meta);
    destination_node.copyPublishedToStagingRev(destination_meta);
    const sfwd = source_node.stagingFwd(source_meta);
    const srev = destination_node.stagingRev(destination_meta);

    var allocs = common.MutationScratch{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const forward_build = try applyRemovalPlanSide(graph, sfwd, &source_pubfwd, forward_plan, .fwd, &allocs);
    const reverse_build = try applyRemovalPlanSide(graph, srev, &dest_pubrev, reverse_plan, .rev, &allocs);
    var source_publish_adj = nodeAdjForSide(sfwd.*, source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    var destination_publish_adj = nodeAdjForSide(srev.*, destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    allocs.disarm();

    if (source_meta.degree_fwd == 0) return error.CorruptGraph;
    if (destination_meta.degree_rev == 0) return error.CorruptGraph;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(source_meta)) == @as(u64, @bitCast(destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(source_node, source_meta, merged_flags, -1, -1);
    } else {
        _ = common.publishStagedRev(destination_node, destination_meta, destination_publish_adj.flags.needs_repair_rev, -1);
        _ = common.publishStagedFwd(source_node, source_meta, source_publish_adj.flags.needs_repair_fwd, -1);
    }

    try rcu.retireBlockFwd(graph, forward_build.old_block);
    try rcu.retireBlockRev(graph, reverse_build.old_block);
    if (forward_build.new_live == 0) try rcu.retireBlockFwd(graph, forward_build.new_block);
    if (reverse_build.new_live == 0) try rcu.retireBlockRev(graph, reverse_build.new_block);

    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchSub(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return true;
}

/// Rebuilds a forward side adjacency, removing all edges to `destination_index`.
/// Returns the new SideAdj and the number of edges removed.
fn rebuildForwardRemoveAll(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_index: u32,
    scratch: *common.MutationScratch,
) !struct { new_side: types.SideAdj, removed: u32 } {
    var block_list: std.ArrayList(u32) = .empty;
    defer block_list.deinit(graph.allocator);
    var total_removed: u32 = 0;

    if (published_side.group_count == 0) {
        const first = published_side.first_block;
        for (first..first + published_side.block_count) |block_idx| {
            total_removed += try copyBlockWithoutDestination(
                graph, @intCast(block_idx), destination_index, scratch, &block_list,
            );
        }
    } else {
        var group_idx = published_side.first_group;
        var visited: u16 = 0;
        while (visited < published_side.group_count) : (visited += 1) {
            if (group_idx == constants.END_OF_CHAIN) break;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                total_removed += try copyBlockWithoutDestination(
                    graph, @intCast(block_idx), destination_index, scratch, &block_list,
                );
            }
            group_idx = group.next;
        }
    }

    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list.items, scratch);
    return .{ .new_side = new_side, .removed = total_removed };
}

/// COW-copies a forward block, stripping all edges to `destination_index`.
/// Returns number of edges removed from this block. Appends to `block_list`
/// if the resulting block is non-empty.
fn copyBlockWithoutDestination(
    graph: *graph_core.GraphCore,
    block_idx: u32,
    destination_index: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const old_ids = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
    const live = @popCount(old_block.mask);
    if (live == 0) return 0;

    var removed: u32 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination == destination_index) removed += 1;
    }
    if (removed == 0) {
        try block_list.append(graph.allocator, block_idx);
        return 0;
    }

    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .fwd);
    const new_ids = page_ops.edgeBlockFwdIdsAt(graph, new_block_idx);
    var write: u7 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination != destination_index) {
            new_block.edges[write] = old_block.edges[slot];
            new_ids.ids[write] = old_ids.ids[slot];
            write += 1;
        }
    }
    new_block.mask = constants.denseMask(write);
    try block_list.append(graph.allocator, new_block_idx);
    return removed;
}

/// Rebuilds a reverse side adjacency, removing `remove_count` occurrences
/// of `source_index`. Returns the new SideAdj.
fn rebuildReverseRemoveCount(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    source_index: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    var block_list: std.ArrayList(u32) = .empty;
    defer block_list.deinit(graph.allocator);
    var remaining = remove_count;

    if (published_side.group_count == 0) {
        const first = published_side.first_block;
        for (first..first + published_side.block_count) |block_idx| {
            remaining = try copyReverseBlockRemoveSource(
                graph, @intCast(block_idx), source_index, remaining, scratch, &block_list,
            );
        }
    } else {
        var group_idx = published_side.first_group;
        var visited: u16 = 0;
        while (visited < published_side.group_count) : (visited += 1) {
            if (group_idx == constants.END_OF_CHAIN or remaining == 0) break;
            const group = page_ops.groupAtConst(graph, group_idx);
            for (group.start..group.start + group.count) |block_idx| {
                remaining = try copyReverseBlockRemoveSource(
                    graph, @intCast(block_idx), source_index, remaining, scratch, &block_list,
                );
                if (remaining == 0) break;
            }
            group_idx = group.next;
        }
    }

    if (remaining > 0) return error.CorruptGraph;

    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list.items, scratch);
    return new_side;
}

fn copyReverseBlockRemoveSource(
    graph: *graph_core.GraphCore,
    block_idx: u32,
    source_index: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const live = @popCount(old_block.mask);
    if (live == 0) return remove_count;

    var in_block: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_index) in_block += 1;
    }
    if (in_block == 0) {
        try block_list.append(graph.allocator, block_idx);
        return remove_count;
    }

    const take = @min(in_block, remove_count);
    const new_live: u7 = @intCast(live - take);
    if (new_live == 0) return remove_count - take;

    const new_block_idx = try scratch.allocBlock(graph, .rev);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .rev);
    var write: u7 = 0;
    var skipped: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_index and skipped < take) {
            skipped += 1;
        } else {
            new_block.sources[write] = old_block.sources[slot];
            write += 1;
        }
    }
    new_block.mask = constants.denseMask(write);
    try block_list.append(graph.allocator, new_block_idx);
    return remove_count - take;
}
