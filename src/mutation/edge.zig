//! Edge insertion and removal — mutable edge operations built on the shared
//! RCU + COW mutation machinery with per-side publication.

const constants = @import("../constants.zig");
const graph_core = @import("../graph_core.zig");
const types = @import("../types.zig");
const page_ops = @import("../page_ops.zig");
const adjacency = @import("../adjacency.zig");
const rcu = @import("../rcu.zig");
const repair = @import("../repair.zig");
const common = @import("common.zig");
const node_validity = @import("../node_validity.zig");
const std = @import("std");

const PreparedAppendBlock = struct {
    old_block: ?u32 = null,
    new_block: u32,
    tail_index: ?u32 = null,
};

const AddEdgeScratch = struct {
    forward_block: ?u32 = null,
    reverse_block: ?u32 = null,
    groups: std.ArrayList(u32) = .empty,
    active: bool = true,

    fn allocBlock(self: *AddEdgeScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
        const block = try page_ops.allocBlock(graph, side);
        switch (side) {
            .fwd => self.forward_block = block,
            .rev => self.reverse_block = block,
        }
        return block;
    }

    fn allocGroup(self: *AddEdgeScratch, graph: *graph_core.GraphCore) !u32 {
        const group = try page_ops.allocGroup(graph);
        self.groups.append(graph.allocator, group) catch |err| {
            page_ops.freeGroup(graph, group);
            return err;
        };
        return group;
    }

    fn freeTrackedGroup(self: *AddEdgeScratch, graph: *graph_core.GraphCore, group: u32) void {
        for (self.groups.items, 0..) |g, i| {
            if (g == group) {
                _ = self.groups.swapRemove(i);
                page_ops.freeGroup(graph, group);
                return;
            }
        }
        page_ops.freeGroup(graph, group);
    }

    fn disarm(self: *AddEdgeScratch) void {
        self.active = false;
    }

    fn cleanup(self: *AddEdgeScratch, graph: *graph_core.GraphCore) void {
        if (!self.active) return;
        if (self.forward_block) |block| page_ops.freeBlock(graph, block, .fwd);
        if (self.reverse_block) |block| page_ops.freeBlock(graph, block, .rev);
        for (self.groups.items) |group| page_ops.freeGroup(graph, group);
    }

    fn deinit(self: *AddEdgeScratch, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
    }
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

fn prepareAppendBlockSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *AddEdgeScratch,
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

fn cloneGroupsForStagingSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    scratch: *AddEdgeScratch,
) !void {
    const expected_groups = side_adj.group_count;
    if (expected_groups == 0) return;

    var old_group_index = side_adj.first_group;
    var new_first_group: u32 = constants.END_OF_CHAIN;
    var previous_new_group: ?u32 = null;
    var copied_groups: u16 = 0;

    while (copied_groups < expected_groups) : (copied_groups += 1) {
        if (old_group_index == constants.END_OF_CHAIN or old_group_index >= graph.group_count) return error.CorruptGraph;
        const old_group = page_ops.groupAtConst(graph, old_group_index).*;
        const new_group_index = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{
            .start = old_group.start, .next = constants.END_OF_CHAIN, .count = old_group.count,
        };
        if (previous_new_group) |previous| {
            page_ops.groupAt(graph, previous).next = new_group_index;
        } else {
            new_first_group = new_group_index;
        }
        previous_new_group = new_group_index;
        old_group_index = old_group.next;
    }
    if (old_group_index != constants.END_OF_CHAIN) return error.CorruptGraph;
    side_adj.first_group = new_first_group;
}

fn appendGroupToSideAdjTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    new_block: u32,
    scratch: *AddEdgeScratch,
) !void {
    if (side_adj.group_count == 0) {
        const prefix_group_index = try scratch.allocGroup(graph);
        const new_group_index = try scratch.allocGroup(graph);
        page_ops.groupAt(graph, prefix_group_index).* = types.EdgeBlockGroup{
            .start = side_adj.first_block, .count = side_adj.block_count, .next = new_group_index,
        };
        page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{ .start = new_block, .count = 1, .next = constants.END_OF_CHAIN };
        side_adj.first_group = prefix_group_index;
        side_adj.group_count = 2;
        return;
    }

    const new_group_index = try scratch.allocGroup(graph);
    page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{ .start = new_block, .count = 1, .next = constants.END_OF_CHAIN };

    var group_index = side_adj.first_group;
    var append_visited: u16 = 0;
    while (true) {
        if (group_index >= graph.group_count) return error.CorruptGraph;
        if (append_visited >= side_adj.group_count) return error.CorruptGraph;
        append_visited += 1;
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) {
            page_ops.groupAt(graph, group_index).next = new_group_index;
            break;
        }
        group_index = group.next;
    }
    side_adj.group_count += 1;
}

fn removeTailFromSideAdjTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    scratch: *AddEdgeScratch,
) !void {
    if (side_adj.group_count > 0) {
        var group_index = side_adj.first_group;
        var prev_group: ?u32 = null;
        var remove_visited: u16 = 0;
        while (true) {
            if (group_index >= graph.group_count) return error.CorruptGraph;
            if (remove_visited >= side_adj.group_count) return error.CorruptGraph;
            remove_visited += 1;
            const group = page_ops.groupAt(graph, group_index);
            if (group.next == constants.END_OF_CHAIN) {
                std.debug.assert(group.count > 0);
                page_ops.groupAt(graph, group_index).count -= 1;
                if (page_ops.groupAt(graph, group_index).count == 0) {
                    if (prev_group) |prev| {
                        page_ops.groupAt(graph, prev).next = constants.END_OF_CHAIN;
                        side_adj.group_count -= 1;
                    } else {
                        side_adj.group_count = 0;
                        side_adj.first_group = 0;
                    }
                    scratch.freeTrackedGroup(graph, group_index);
                }
                break;
            }
            prev_group = group_index;
            group_index = group.next;
        }
    } else {
        std.debug.assert(side_adj.block_count > 0);
        side_adj.block_count -= 1;
    }
}

fn cloneGroupsForStagingIfNeededSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    scratch: *AddEdgeScratch,
) !OldGroupChain {
    const old_groups = OldGroupChain.captureSide(side_adj);
    if (old_groups.first_group != null) {
        try cloneGroupsForStagingSideTracked(graph, side_adj, scratch);
    }
    return old_groups;
}

fn applyPreparedAppendSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: PreparedAppendBlock,
    comptime _: adjacency.AdjSide,
    scratch: *AddEdgeScratch,
) !void {
    if (side_adj.block_count == 0) {
        side_adj.first_block = prepared.new_block;
        side_adj.block_count = 1;
        return;
    }

    if (prepared.old_block != null) {
        if (side_adj.block_count == 1) {
            side_adj.first_block = prepared.new_block;
            if (side_adj.group_count == 1) {
                page_ops.groupAt(graph, side_adj.first_group).start = prepared.new_block;
            }
        } else {
            const was_contiguous = side_adj.group_count == 0;
            try removeTailFromSideAdjTracked(graph, side_adj, scratch);
            try appendGroupToSideAdjTracked(graph, side_adj, prepared.new_block, scratch);
            if (was_contiguous) side_adj.block_count += 1;
        }
        return;
    }

    const tail_index = prepared.tail_index.?;
    if (prepared.new_block == tail_index + 1) {
        if (side_adj.group_count > 0) adjacency.extendTailGroupSide(graph, side_adj);
        side_adj.block_count += 1;
        return;
    }

    if (side_adj.group_count >= constants.MAX_GROUPS_PER_NODE) return error.RepairRequired;
    try appendGroupToSideAdjTracked(graph, side_adj, prepared.new_block, scratch);
    side_adj.block_count += 1;
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
    allocs: *common.PrePublishAllocations,
) !RemovalBuild {
    const old_block = plan.found.block_idx;
    const new_block = try allocs.allocBlock(graph, side);
    const new_live: u7 = plan.live_before - 1;

    switch (side) {
        .fwd => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .fwd);
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = block_before.*;
            const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) block.edges[shift] = block.edges[shift + 1];
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

    try common.rebuildAdjWithReplaceSide(
        graph, staging_side,
        published_side.first_block, published_side.block_count,
        published_side.group_count, published_side.first_group,
        old_block, new_block, side, allocs,
    );

    return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
}

/// Adds a directed edge `source → destination` with a relation label and flags.
pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    if (!node_validity.nodeExistsRaw(graph, source) or !node_validity.nodeExistsRaw(graph, destination)) return error.InvalidNode;

    const source_node = page_ops.nodeAt(graph, source);
    const destination_node = page_ops.nodeAt(graph, destination);

    var claims = try common.tryClaimAdjacencies(source_node, destination_node, source.index, destination.index);
    defer claims.release();

    const source_meta = source_node.loadPublishedMeta();
    const destination_meta = destination_node.loadPublishedMeta();
    const source_adj_before = source_node.publishedAdjFromMeta(source_meta);
    const destination_adj_before = destination_node.publishedAdjFromMeta(destination_meta);
    const source_pub = source_node.publishedFwdFromMeta(source_meta);
    if (!node_validity.snapshotIsLive(source_adj_before) or !node_validity.snapshotIsLive(destination_adj_before)) {
        return error.InvalidNode;
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    source_node.copyPublishedToStagingFwd(source_meta);
    destination_node.copyPublishedToStagingRev(destination_meta);
    const sfwd = source_node.stagingFwd(source_meta);
    const srev = destination_node.stagingRev(destination_meta);

    if (adjacency.hasEdgeInSideAdj(graph, source_pub, destination.index)) {
        return error.EdgeAlreadyExists;
    }

    if (source_meta.degree_fwd >= constants.MAX_DEGREE_PER_SIDE) return error.OutOfMemory;
    if (destination_meta.degree_rev >= constants.MAX_DEGREE_PER_SIDE) return error.OutOfMemory;
    if (@as(u22, source_adj_before.block_count_fwd) >= constants.MAX_BLOCKS_PER_SIDE) return error.OutOfMemory;
    if (@as(u22, destination_adj_before.block_count_rev) >= constants.MAX_BLOCKS_PER_SIDE) return error.OutOfMemory;

    var scratch = AddEdgeScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const forward_prepared = try prepareAppendBlockSide(graph, sfwd, .fwd, &scratch);
    const reverse_prepared = try prepareAppendBlockSide(graph, srev, .rev, &scratch);

    try ensureTailCowGroupConstraintSide(graph, sfwd, forward_prepared);
    try ensureTailCowGroupConstraintSide(graph, srev, reverse_prepared);

    const old_forward_groups = try cloneGroupsForStagingIfNeededSideTracked(graph, sfwd, &scratch);
    const old_reverse_groups = try cloneGroupsForStagingIfNeededSideTracked(graph, srev, &scratch);

    try applyPreparedAppendSideTracked(graph, sfwd, forward_prepared, .fwd, &scratch);
    try insertForwardEdge(graph, forward_prepared.new_block, destination, relation, flags);
    var source_publish_adj = source_adj_before;
    source_publish_adj.first_block_fwd = sfwd.first_block;
    source_publish_adj.block_count_fwd = sfwd.block_count;
    source_publish_adj.group_count_fwd = sfwd.group_count;
    source_publish_adj.first_group_fwd = sfwd.first_group;
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    try applyPreparedAppendSideTracked(graph, srev, reverse_prepared, .rev, &scratch);
    insertReverseEdge(graph, reverse_prepared.new_block, source);
    var destination_publish_adj = destination_adj_before;
    destination_publish_adj.first_block_rev = srev.first_block;
    destination_publish_adj.block_count_rev = srev.block_count;
    destination_publish_adj.group_count_rev = srev.group_count;
    destination_publish_adj.first_group_rev = srev.first_group;
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    scratch.disarm();

    const new_source_degree: u22 = @as(u22, @intCast(source_meta.degree_fwd)) + 1;
    const new_dest_degree: u22 = @as(u22, @intCast(destination_meta.degree_rev)) + 1;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(source_meta)) == @as(u64, @bitCast(destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishStagedBoth(source_node, source_meta, merged_flags, new_source_degree, new_dest_degree);
    } else {
        // publish reverse first, then forward (RFC §5.2)
        _ = common.publishStagedRev(destination_node, destination_meta, destination_publish_adj.flags.needs_repair_rev, new_dest_degree);
        _ = common.publishStagedFwd(source_node, source_meta, source_publish_adj.flags.needs_repair_fwd, new_source_degree);
    }

    if (forward_prepared.old_block) |old_block| try rcu.retireBlockFwd(graph, old_block);
    if (reverse_prepared.old_block) |old_block| try rcu.retireBlockRev(graph, old_block);
    old_forward_groups.retire(graph);
    old_reverse_groups.retire(graph);

    _ = graph.edge_count.fetchAdd(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);
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
    const source_adj = source_node.publishedAdjFromMeta(source_meta);
    const destination_adj = destination_node.publishedAdjFromMeta(destination_meta);
    if (!node_validity.snapshotIsLive(source_adj) or !node_validity.snapshotIsLive(destination_adj)) {
        return error.InvalidNode;
    }

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const source_pubfwd = source_node.publishedFwdFromMeta(source_meta);
    const dest_pubrev = destination_node.publishedRevFromMeta(destination_meta);

    const old_forward_groups = OldGroupChain.captureSide(&source_pubfwd);
    const old_reverse_groups = OldGroupChain.captureSide(&dest_pubrev);

    const forward_found = common.findSlotInAdj(
        graph, source_pubfwd.first_block, source_pubfwd.block_count,
        source_pubfwd.group_count, source_pubfwd.first_group,
        destination.index, .fwd,
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

    var allocs = common.PrePublishAllocations{};
    defer allocs.deinit(graph.allocator);
    defer allocs.cleanup(graph);

    const forward_build = try applyRemovalPlanSide(graph, sfwd, &source_pubfwd, forward_plan, .fwd, &allocs);
    const reverse_build = try applyRemovalPlanSide(graph, srev, &dest_pubrev, reverse_plan, .rev, &allocs);
    var source_publish_adj = source_adj;
    source_publish_adj.first_block_fwd = sfwd.first_block;
    source_publish_adj.block_count_fwd = sfwd.block_count;
    source_publish_adj.group_count_fwd = sfwd.group_count;
    source_publish_adj.first_group_fwd = sfwd.first_group;
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    var destination_publish_adj = destination_adj;
    destination_publish_adj.first_block_rev = srev.first_block;
    destination_publish_adj.block_count_rev = srev.block_count;
    destination_publish_adj.group_count_rev = srev.group_count;
    destination_publish_adj.first_group_rev = srev.first_group;
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    allocs.disarm();

    const new_source_degree: u22 = @as(u22, @intCast(source_meta.degree_fwd)) - 1;
    const new_dest_degree: u22 = @as(u22, @intCast(destination_meta.degree_rev)) - 1;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(source_meta)) == @as(u64, @bitCast(destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishStagedBoth(source_node, source_meta, merged_flags, new_source_degree, new_dest_degree);
    } else {
        // publish reverse first, then forward (RFC §5.2)
        _ = common.publishStagedRev(destination_node, destination_meta, destination_publish_adj.flags.needs_repair_rev, new_dest_degree);
        _ = common.publishStagedFwd(source_node, source_meta, source_publish_adj.flags.needs_repair_fwd, new_source_degree);
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
