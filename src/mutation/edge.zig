//! Edge insertion and removal — mutable edge operations built on the shared
//! RCU + COW mutation machinery.

const constants = @import("../constants.zig");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const page_ops = @import("../page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../repair.zig");
const common = @import("common.zig");

const StagedAdj = struct {
    published_index: u1,
    staging_adj: *types.NodeAdj,
};

const PreparedAppendBlock = struct {
    old_block: ?u32 = null,
    new_block: u32,
    tail_index: ?u32 = null,
};

const OldGroupChain = struct {
    first_group: ?u32 = null,
    group_count: u16 = 0,

    fn capture(node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) OldGroupChain {
        const count = adjGroupCount(node_adj, side);
        return .{
            .first_group = if (count > 0) adjFirstGroup(node_adj, side) else null,
            .group_count = count,
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

fn adjFirstBlock(node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) u32 {
    return if (side == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
}

fn adjBlockCount(node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) u16 {
    return if (side == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
}

fn adjGroupCount(node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) u16 {
    return if (side == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
}

fn adjFirstGroup(node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) u32 {
    return if (side == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
}

fn setAdjFirstBlock(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide, value: u32) void {
    if (side == .fwd) {
        node_adj.first_block_fwd = value;
    } else {
        node_adj.first_block_rev = value;
    }
}

fn setAdjBlockCount(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide, value: u16) void {
    if (side == .fwd) {
        node_adj.block_count_fwd = value;
    } else {
        node_adj.block_count_rev = value;
    }
}

fn incrementAdjBlockCount(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide) void {
    if (side == .fwd) {
        node_adj.block_count_fwd += 1;
    } else {
        node_adj.block_count_rev += 1;
    }
}

fn stageAdjForMutation(node: *types.NodeBuffer) StagedAdj {
    const published_index = node.loadPublishedAdjIndex();
    const staging_index: u1 = 1 - published_index;
    node.copyPublishedToStaging();
    return .{
        .published_index = published_index,
        .staging_adj = &node.adj_buffers[staging_index],
    };
}

fn publishEndpoints(source_node: *types.NodeBuffer, destination_node: *types.NodeBuffer, source: types.NodeId, destination: types.NodeId) void {
    if (source.index == destination.index) {
        source_node.publishStagingAdj();
    } else {
        destination_node.publishStagingAdj();
        source_node.publishStagingAdj();
    }
}

fn prepareAppendBlock(graph: *graph_core.GraphCore, node_adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) !PreparedAppendBlock {
    if (adjBlockCount(node_adj, side) == 0) {
        return .{ .new_block = try page_ops.allocBlock(graph, side) };
    }

    const tail_index = switch (side) {
        .fwd => adjacency.tailBlockIndex(graph, node_adj, .fwd),
        .rev => adjacency.tailBlockIndex(graph, node_adj, .rev),
    };
    const new_block = try page_ops.allocBlock(graph, side);

    switch (side) {
        .fwd => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_index, .fwd);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_index };
            }
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = tail_block.*;
        },
        .rev => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_index, .rev);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_index };
            }
            page_ops.edgeBlockAt(graph, new_block, .rev).* = tail_block.*;
        },
    }

    return .{
        .old_block = tail_index,
        .new_block = new_block,
        .tail_index = tail_index,
    };
}

fn ensureTailCowGroupConstraint(
    graph: *graph_core.GraphCore,
    node_adj: *const types.NodeAdj,
    prepared: PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
) !void {
    if (prepared.old_block == null) return;
    if (adjBlockCount(node_adj, side) <= 1) return;
    if (adjGroupCount(node_adj, side) < constants.MAX_GROUPS_PER_NODE) return;

    const tail_index = prepared.tail_index.?;
    var group_index = adjFirstGroup(node_adj, side);
    while (group_index != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_index);
        if (tail_index >= group.start and tail_index < group.start + group.count) {
            if (group.count > 1) return error.RepairRequired;
            break;
        }
        group_index = group.next;
    }
}

fn cloneGroupsForStagingIfNeeded(
    graph: *graph_core.GraphCore,
    node_adj: *types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !OldGroupChain {
    const old_groups = OldGroupChain.capture(node_adj, side);
    if (old_groups.first_group != null) {
        switch (side) {
            .fwd => try adjacency.cloneGroupsForStaging(graph, node_adj, .fwd),
            .rev => try adjacency.cloneGroupsForStaging(graph, node_adj, .rev),
        }
    }
    return old_groups;
}

fn applyPreparedAppend(
    graph: *graph_core.GraphCore,
    node_adj: *types.NodeAdj,
    prepared: PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
) !void {
    const block_count = adjBlockCount(node_adj, side);
    if (block_count == 0) {
        setAdjFirstBlock(node_adj, side, prepared.new_block);
        setAdjBlockCount(node_adj, side, 1);
        return;
    }

    if (prepared.old_block != null) {
        if (block_count == 1) {
            setAdjFirstBlock(node_adj, side, prepared.new_block);
        } else {
            const was_contiguous = adjGroupCount(node_adj, side) == 0;
            switch (side) {
                .fwd => {
                    adjacency.removeTailFromAdj(graph, node_adj, .fwd);
                    try adjacency.appendGroupToAdj(graph, node_adj, prepared.new_block, .fwd);
                },
                .rev => {
                    adjacency.removeTailFromAdj(graph, node_adj, .rev);
                    try adjacency.appendGroupToAdj(graph, node_adj, prepared.new_block, .rev);
                },
            }
            if (was_contiguous) incrementAdjBlockCount(node_adj, side);
        }
        return;
    }

    const tail_index = prepared.tail_index.?;
    if (prepared.new_block == tail_index + 1) {
        if (adjGroupCount(node_adj, side) > 0) {
            switch (side) {
                .fwd => adjacency.extendTailGroup(graph, node_adj, .fwd),
                .rev => adjacency.extendTailGroup(graph, node_adj, .rev),
            }
        }
        incrementAdjBlockCount(node_adj, side);
        return;
    }

    if (adjGroupCount(node_adj, side) >= constants.MAX_GROUPS_PER_NODE) {
        return error.RepairRequired;
    }
    switch (side) {
        .fwd => try adjacency.appendGroupToAdj(graph, node_adj, prepared.new_block, .fwd),
        .rev => try adjacency.appendGroupToAdj(graph, node_adj, prepared.new_block, .rev),
    }
    incrementAdjBlockCount(node_adj, side);
}

fn insertForwardEdge(graph: *graph_core.GraphCore, block_index: u32, destination: types.NodeId, relation: u16, flags: u16) !void {
    const forward_block = page_ops.edgeBlockAt(graph, block_index, .fwd);
    const live = @popCount(forward_block.mask);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(live);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (forward_block.edges[probe].destination < destination.index) {
            insertion_point = probe + 1;
        } else if (forward_block.edges[probe].destination == destination.index) {
            return error.EdgeAlreadyExists;
        } else {
            search_end = probe;
        }
    }

    var shift: u7 = @intCast(live);
    while (shift > insertion_point) {
        forward_block.edges[shift] = forward_block.edges[shift - 1];
        shift -= 1;
    }
    forward_block.edges[insertion_point] = types.Edge{ .destination = destination.index, .relation = relation, .flags = @bitCast(flags) };
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

fn planRemoval(
    graph: *graph_core.GraphCore,
    published_adj: *const types.NodeAdj,
    found: common.AdjSlot,
    comptime side: adjacency.AdjSide,
) !RemovalPlan {
    const live_before: u7 = switch (side) {
        .fwd => @intCast(@popCount(page_ops.edgeBlockAtConst(graph, found.block_idx, .fwd).mask)),
        .rev => @intCast(@popCount(page_ops.edgeBlockAtConst(graph, found.block_idx, .rev).mask)),
    };
    const new_live: u7 = live_before - 1;
    const tail_index = switch (side) {
        .fwd => adjacency.tailBlockIndex(graph, published_adj, .fwd),
        .rev => adjacency.tailBlockIndex(graph, published_adj, .rev),
    };
    const is_tail = found.block_idx == tail_index;
    if (!is_tail and new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    return .{
        .found = found,
        .live_before = live_before,
    };
}

fn applyRemovalPlan(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    published_adj: *const types.NodeAdj,
    plan: RemovalPlan,
    comptime side: adjacency.AdjSide,
) !void {
    const old_block = plan.found.block_idx;
    const new_block = try page_ops.allocBlock(graph, side);
    const new_live: u7 = plan.live_before - 1;

    switch (side) {
        .fwd => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .fwd);
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = block_before.*;

            const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) {
                block.edges[shift] = block.edges[shift + 1];
            }
            block.mask = constants.denseMask(@intCast(new_live));
        },
        .rev => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .rev);
            page_ops.edgeBlockAt(graph, new_block, .rev).* = block_before.*;

            const block = page_ops.edgeBlockAt(graph, new_block, .rev);
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) {
                block.sources[shift] = block.sources[shift + 1];
            }
            block.mask = constants.denseMask(@intCast(new_live));
        },
    }

    try common.rebuildAdjWithReplace(
        graph,
        staging_adj,
        adjFirstBlock(published_adj, side),
        adjBlockCount(published_adj, side),
        adjGroupCount(published_adj, side),
        adjFirstGroup(published_adj, side),
        old_block,
        new_block,
        side,
    );

    switch (side) {
        .fwd => try rcu.retireBlockFwd(graph, old_block),
        .rev => try rcu.retireBlockRev(graph, old_block),
    }

    // If the new block ended up empty, rebuildAdjWithReplace skipped it
    // and it was never inserted into the adjacency.  Retire it so it is
    // reclaimed together with the old block.
    if (new_live == 0) {
        switch (side) {
            .fwd => try rcu.retireBlockFwd(graph, new_block),
            .rev => try rcu.retireBlockRev(graph, new_block),
        }
    }
}

/// Adds a directed edge `source → destination` with a relation label and flags.
///
/// Fails with:
///   - `InvalidNode` if either endpoint does not exist.
///   - `EdgeAlreadyExists` if the edge is already present (non-multigraph mode).
///
/// Follows the RCU + COW mutation model.
pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    if (source.index >= graph.node_count or destination.index >= graph.node_count) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_stage = stageAdjForMutation(source_node);
    const destination_stage = stageAdjForMutation(destination_node);

    if (adjacency.hasEdgeInAdj(graph, source_node.adj_buffers[source_stage.published_index], destination.index)) {
        return error.EdgeAlreadyExists;
    }

    const forward_prepared = try prepareAppendBlock(graph, source_stage.staging_adj, .fwd);
    const reverse_prepared = try prepareAppendBlock(graph, destination_stage.staging_adj, .rev);

    try ensureTailCowGroupConstraint(graph, source_stage.staging_adj, forward_prepared, .fwd);
    try ensureTailCowGroupConstraint(graph, destination_stage.staging_adj, reverse_prepared, .rev);

    const old_forward_groups = try cloneGroupsForStagingIfNeeded(graph, source_stage.staging_adj, .fwd);
    const old_reverse_groups = try cloneGroupsForStagingIfNeeded(graph, destination_stage.staging_adj, .rev);

    try applyPreparedAppend(graph, source_stage.staging_adj, forward_prepared, .fwd);
    try insertForwardEdge(graph, forward_prepared.new_block, destination, relation, flags);

    try applyPreparedAppend(graph, destination_stage.staging_adj, reverse_prepared, .rev);
    insertReverseEdge(graph, reverse_prepared.new_block, source);

    publishEndpoints(source_node, destination_node, source, destination);
    common.incrementDegree(&source_node.degree_fwd);
    common.incrementDegree(&destination_node.degree_rev);

    if (forward_prepared.old_block) |old_block| try rcu.retireBlockFwd(graph, old_block);
    if (reverse_prepared.old_block) |old_block| try rcu.retireBlockRev(graph, old_block);
    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchAdd(1, .monotonic);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);
}

/// Removes the directed edge `source → destination` if it exists, returning `true`.
/// Returns `false` if the edge was not found (no mutation performed).
///
/// Fails with:
///   - `InvalidNode` if either endpoint does not exist.
///   - `CorruptGraph` if forward and reverse adjacency disagree (internal invariant).
///   - `RepairRequired` if a non-tail block would drop below `MIN_OCCUPANCY`.
///
/// Follows the RCU + COW mutation model. Works for any block position
/// (first, middle, or last) in both contiguous and grouped adjacency chains.
pub fn removeEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId) !bool {
    if (source.index >= graph.node_count or destination.index >= graph.node_count) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_adj = source_node.publishedAdj();
    const destination_adj = destination_node.publishedAdj();
    const old_forward_groups = OldGroupChain.capture(&source_adj, .fwd);
    const old_reverse_groups = OldGroupChain.capture(&destination_adj, .rev);

    const forward_found = common.findSlotInAdj(
        graph,
        source_adj.first_block_fwd,
        source_adj.block_count_fwd,
        source_adj.group_count_fwd,
        source_adj.first_group_fwd,
        destination.index,
        .fwd,
    ) orelse return false;

    const reverse_found = common.findSlotInAdj(
        graph,
        destination_adj.first_block_rev,
        destination_adj.block_count_rev,
        destination_adj.group_count_rev,
        destination_adj.first_group_rev,
        source.index,
        .rev,
    ) orelse return error.CorruptGraph;

    const forward_plan = try planRemoval(graph, &source_adj, forward_found, .fwd);
    const reverse_plan = try planRemoval(graph, &destination_adj, reverse_found, .rev);

    source_node.copyPublishedToStaging();
    const source_staging_adj = source_node.stagingAdj();

    destination_node.copyPublishedToStaging();
    const destination_staging_adj = destination_node.stagingAdj();

    try applyRemovalPlan(graph, source_staging_adj, &source_adj, forward_plan, .fwd);
    try applyRemovalPlan(graph, destination_staging_adj, &destination_adj, reverse_plan, .rev);

    repair.updateRepairDebt(graph, source_staging_adj, source.index, .fwd);
    repair.updateRepairDebt(graph, destination_staging_adj, destination.index, .rev);
    publishEndpoints(source_node, destination_node, source, destination);
    common.decrementDegree(&source_node.degree_fwd);
    common.decrementDegree(&destination_node.degree_rev);
    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchSub(1, .monotonic);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return true;
}
