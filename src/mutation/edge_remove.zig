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
const local_side_edit = @import("local_side_edit.zig");
const structural_rebuild = @import("structural_rebuild.zig");

const RemovalPlan = struct {
    found: common.AdjSlot,
    live_before: u7,
};

const RemovalBuild = struct {
    old_block: u32,
    new_block: u32,
    new_live: u7,
};

const DestinationMatchProbe = struct {
    found: ?common.AdjSlot = null,
    has_multiple: bool = false,
};

const RemoveState = struct {
    source_pub: types.SideAdj,
    destination_pub: types.SideAdj,
    old_source_groups: shared.OldGroupChain,
    old_destination_groups: shared.OldGroupChain,
};

const ForwardDestinationProbeContext = struct {
    destination_idx: u32,
    result: *DestinationMatchProbe,
};

const ForwardRemovalContext = struct {
    destination_idx: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    removed: u32 = 0,
};

const ReverseRemovalContext = struct {
    source_idx: u32,
    remaining: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
};

fn loadRemoveState(endpoints: *const shared.EndpointState) RemoveState {
    const source_pub = endpoints.source_node.publishedFwdFromMeta(endpoints.source_meta);
    const destination_pub = endpoints.destination_node.publishedRevFromMeta(endpoints.destination_meta);
    return .{
        .source_pub = source_pub,
        .destination_pub = destination_pub,
        .old_source_groups = shared.OldGroupChain.captureSide(&source_pub),
        .old_destination_groups = shared.OldGroupChain.captureSide(&destination_pub),
    };
}

fn publishRemoved(
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
) !void {
    if (endpoints.source_meta.degree_fwd == 0) return error.CorruptGraph;
    if (endpoints.destination_meta.degree_rev == 0) return error.CorruptGraph;

    if (source.index == destination.index) {
        std.debug.assert(@as(u64, @bitCast(endpoints.source_meta)) == @as(u64, @bitCast(endpoints.destination_meta)));
        var merged_flags = source_publish_adj.flags;
        merged_flags.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = source_publish_adj.flags.removed or destination_publish_adj.flags.removed;
        _ = common.publishBothDelta(endpoints.source_node, endpoints.source_meta, merged_flags, -1, -1);
        return;
    }

    _ = common.publishStagedRev(endpoints.destination_node, endpoints.destination_meta, destination_publish_adj.flags.needs_repair_rev, -1);
    _ = common.publishStagedFwd(endpoints.source_node, endpoints.source_meta, source_publish_adj.flags.needs_repair_fwd, -1);
}

fn retireRemoved(
    graph: *graph_core.GraphCore,
    remove_state: RemoveState,
    source_build: RemovalBuild,
    destination_build: RemovalBuild,
) !void {
    try rcu.retireBlockFwd(graph, source_build.old_block);
    try rcu.retireBlockRev(graph, destination_build.old_block);
    if (source_build.new_live == 0) try rcu.retireBlockFwd(graph, source_build.new_block);
    if (destination_build.new_live == 0) try rcu.retireBlockRev(graph, destination_build.new_block);
    remove_state.old_source_groups.retire(graph);
    remove_state.old_destination_groups.retire(graph);
}

fn removeSingleLocated(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    forward_found: common.AdjSlot,
    allow_structural_rebuild: bool,
) !bool {
    const reverse_found = common.findSlotInAdj(
        graph,
        remove_state.destination_pub.first_block,
        remove_state.destination_pub.block_count,
        remove_state.destination_pub.group_count,
        remove_state.destination_pub.first_group,
        source.index,
        .rev,
    ) orelse return error.CorruptGraph;

    const forward_plan = try planRemovalSide(graph, &remove_state.source_pub, forward_found, .fwd);
    const reverse_plan = try planRemovalSide(graph, &remove_state.destination_pub, reverse_found, .rev);

    if (!allow_structural_rebuild) {
        if (!try local_side_edit.isRemovalLocal(graph, &remove_state.source_pub, forward_found.block_idx)) return error.RepairRequired;
        if (!try local_side_edit.isRemovalLocal(graph, &remove_state.destination_pub, reverse_found.block_idx)) return error.RepairRequired;
    }

    endpoints.source_node.copyPublishedToStagingFwd(endpoints.source_meta);
    endpoints.destination_node.copyPublishedToStagingRev(endpoints.destination_meta);
    const source_staging = endpoints.source_node.stagingFwd(endpoints.source_meta);
    const destination_staging = endpoints.destination_node.stagingRev(endpoints.destination_meta);

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const source_build = try applyRemovalPlanSide(graph, source_staging, &remove_state.source_pub, forward_plan, .fwd, &scratch, allow_structural_rebuild);
    const destination_build = try applyRemovalPlanSide(graph, destination_staging, &remove_state.destination_pub, reverse_plan, .rev, &scratch, allow_structural_rebuild);

    var source_publish_adj = common.nodeAdjForSide(source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    var destination_publish_adj = common.nodeAdjForSide(destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    scratch.disarm();
    try publishRemoved(endpoints, source, destination, source_publish_adj, destination_publish_adj);
    try retireRemoved(graph, remove_state, source_build, destination_build);

    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

fn removeBulkDestinationMatches(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
) !bool {
    const probe = try probeForwardDestinationMatches(graph, &remove_state.source_pub, destination.index);
    if (probe.found == null) return false;
    if (!probe.has_multiple) return removeSingleLocated(graph, endpoints, remove_state, source, destination, probe.found.?, false);

    endpoints.source_node.copyPublishedToStagingFwd(endpoints.source_meta);
    endpoints.destination_node.copyPublishedToStagingRev(endpoints.destination_meta);
    const source_staging = endpoints.source_node.stagingFwd(endpoints.source_meta);
    const destination_staging = endpoints.destination_node.stagingRev(endpoints.destination_meta);

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const forward_result = try rebuildForwardRemoveAll(graph, &remove_state.source_pub, destination.index, &scratch);
    if (forward_result.removed <= 1) return error.CorruptGraph;
    source_staging.* = forward_result.new_side;
    destination_staging.* = try rebuildReverseRemoveCount(graph, &remove_state.destination_pub, source.index, forward_result.removed, &scratch);

    var source_publish_adj = common.nodeAdjForSide(source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);
    var destination_publish_adj = common.nodeAdjForSide(destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    scratch.disarm();

    if (source.index == destination.index) {
        var merged = source_publish_adj.flags;
        merged.needs_repair_rev = destination_publish_adj.flags.needs_repair_rev;
        merged.removed = false;
        _ = common.publishBothDelta(
            endpoints.source_node,
            endpoints.source_meta,
            merged,
            -@as(i23, @intCast(forward_result.removed)),
            -@as(i23, @intCast(forward_result.removed)),
        );
    } else {
        _ = common.publishStagedRev(endpoints.destination_node, endpoints.destination_meta, destination_publish_adj.flags.needs_repair_rev, -@as(i23, @intCast(forward_result.removed)));
        _ = common.publishStagedFwd(endpoints.source_node, endpoints.source_meta, source_publish_adj.flags.needs_repair_fwd, -@as(i23, @intCast(forward_result.removed)));
    }

    try common.retireSide(graph, common.nodeAdjForSide(remove_state.source_pub, endpoints.source_flags, .fwd), .fwd);
    try common.retireSide(graph, common.nodeAdjForSide(remove_state.destination_pub, endpoints.destination_flags, .rev), .rev);
    _ = graph.edge_count.fetchSub(forward_result.removed, .release);
    return true;
}

fn probeForwardDestinationInBlock(
    graph: *const graph_core.GraphCore,
    context: *ForwardDestinationProbeContext,
    block_idx: u32,
) !void {
    if (context.result.has_multiple) return;

    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const matches = adjacency.countForwardInBlock(block, context.destination_idx);
    if (matches == 0) return;

    if (context.result.found == null) {
        context.result.found = .{ .block_idx = block_idx, .slot = adjacency.searchInBlock(types.EdgeBlockFwd, block, context.destination_idx).? };
        if (matches > 1) context.result.has_multiple = true;
    } else {
        context.result.has_multiple = true;
    }
}

fn probeForwardDestinationMatches(
    graph: *const graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    destination_idx: u32,
) !DestinationMatchProbe {
    if (side_adj.block_count == 0) return .{};

    var result: DestinationMatchProbe = .{};
    var context = ForwardDestinationProbeContext{
        .destination_idx = destination_idx,
        .result = &result,
    };
    try common.forEachBlockInSide(graph, side_adj.*, .fwd, &context, probeForwardDestinationInBlock);

    return result;
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
    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, side_adj)) orelse return error.CorruptGraph;
    const is_tail = found.block_idx == tail_idx;
    if (!is_tail and new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;
    return .{ .found = found, .live_before = live_before };
}

fn applyRemovalPlanSide(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    plan: RemovalPlan,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
    allow_structural_rebuild: bool,
) !RemovalBuild {
    if (!allow_structural_rebuild) {
        const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, published_side)) orelse return error.CorruptGraph;
        if (published_side.block_count > 1 and plan.found.block_idx != tail_idx) return error.RepairRequired;
    }

    const old_block = plan.found.block_idx;
    const new_block = try scratch.allocBlock(graph, side);
    if (new_block == old_block) return error.CorruptGraph;
    const new_live: u7 = plan.live_before - 1;

    switch (side) {
        .fwd => {
            const block_before = page_ops.edgeBlockAtConst(graph, old_block, .fwd);
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = block_before.*;
            if (graph.multigraph_enabled) {
                const ids_before = page_ops.edgeBlockFwdIdsAtConst(graph, old_block);
                page_ops.edgeBlockFwdIdsAt(graph, new_block).* = ids_before.*;
            }
            const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
            const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block) else undefined;
            var shift: u7 = plan.found.slot;
            while (shift < plan.live_before - 1) : (shift += 1) {
                block.edges[shift] = block.edges[shift + 1];
                if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift + 1];
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

    if (try local_side_edit.tryApplyRemovalPlanFast(graph, staging_side, published_side, plan.found.block_idx, new_block, new_live, scratch)) {
        return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
    }

    if (!allow_structural_rebuild) return error.RepairRequired;

    try structural_rebuild.rebuildAfterSingleRemoval(graph, staging_side, published_side, old_block, if (new_live > 0) new_block else null, scratch);

    return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
}

fn rebuildForwardRemoveAll(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_idx: u32,
    scratch: *common.MutationScratch,
) !struct { new_side: types.SideAdj, removed: u32 } {
    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var context = ForwardRemovalContext{
        .destination_idx = destination_idx,
        .scratch = scratch,
        .block_list = &block_list,
    };
    try common.forEachBlockInSide(graph, published_side.*, .fwd, &context, collectForwardRemovalBlock);

    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list.items, scratch);
    return .{ .new_side = new_side, .removed = context.removed };
}

fn copyBlockWithoutDestination(
    graph: *graph_core.GraphCore,
    block_idx: u32,
    destination_idx: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const old_ids = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx) else undefined;
    const live = @popCount(old_block.mask);
    if (live == 0) return 0;

    var removed: u32 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination == destination_idx) removed += 1;
    }
    if (removed == 0) {
        const new_block_idx = try scratch.allocBlock(graph, .fwd);
        page_ops.edgeBlockAt(graph, new_block_idx, .fwd).* = old_block.*;
        if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block_idx).* = old_ids.*;
        try block_list.append(graph.allocator, new_block_idx);
        return 0;
    }

    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    const new_block = page_ops.edgeBlockAt(graph, new_block_idx, .fwd);
    const new_ids = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block_idx) else undefined;
    var write: u7 = 0;
    for (0..live) |slot| {
        if (old_block.edges[slot].destination != destination_idx) {
            new_block.edges[write] = old_block.edges[slot];
            if (graph.multigraph_enabled) new_ids.ids[write] = old_ids.ids[slot];
            write += 1;
        }
    }
    new_block.mask = constants.denseMask(write);
    try block_list.append(graph.allocator, new_block_idx);
    return removed;
}

fn collectForwardRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ForwardRemovalContext,
    block_idx: u32,
) !void {
    context.removed += try copyBlockWithoutDestination(
        @constCast(graph),
        block_idx,
        context.destination_idx,
        context.scratch,
        context.block_list,
    );
}

fn rebuildReverseRemoveCount(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    source_idx: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    var block_list = try std.ArrayList(u32).initCapacity(graph.allocator, published_side.block_count);
    defer block_list.deinit(graph.allocator);
    var context = ReverseRemovalContext{
        .source_idx = source_idx,
        .remaining = remove_count,
        .scratch = scratch,
        .block_list = &block_list,
    };
    try common.forEachBlockInSide(graph, published_side.*, .rev, &context, collectReverseRemovalBlock);

    if (context.remaining > 0) return error.CorruptGraph;

    var new_side: types.SideAdj = undefined;
    try common.buildSideFromBlocks(&new_side, graph, block_list.items, scratch);
    return new_side;
}

fn copyReverseBlockRemoveSource(
    graph: *graph_core.GraphCore,
    block_idx: u32,
    source_idx: u32,
    remove_count: u32,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const live = @popCount(old_block.mask);
    if (live == 0) return remove_count;
    if (remove_count == 0) {
        const new_block_idx = try scratch.allocBlock(graph, .rev);
        page_ops.edgeBlockAt(graph, new_block_idx, .rev).* = old_block.*;
        try block_list.append(graph.allocator, new_block_idx);
        return 0;
    }

    var in_block: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_idx) in_block += 1;
    }
    if (in_block == 0) {
        const new_block_idx = try scratch.allocBlock(graph, .rev);
        page_ops.edgeBlockAt(graph, new_block_idx, .rev).* = old_block.*;
        try block_list.append(graph.allocator, new_block_idx);
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
        if (old_block.sources[slot] == source_idx and skipped < take) {
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

fn collectReverseRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ReverseRemovalContext,
    block_idx: u32,
) !void {
    context.remaining = try copyReverseBlockRemoveSource(
        @constCast(graph),
        block_idx,
        context.source_idx,
        context.remaining,
        context.scratch,
        context.block_list,
    );
}

pub fn removeEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId) !bool {
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const remove_state = loadRemoveState(&endpoints);
    const removed = if (graph.multigraph_enabled)
        try removeBulkDestinationMatches(graph, &endpoints, remove_state, source, destination)
    else blk: {
        const forward_found = common.findSlotInAdj(
            graph,
            remove_state.source_pub.first_block,
            remove_state.source_pub.block_count,
            remove_state.source_pub.group_count,
            remove_state.source_pub.first_group,
            destination.index,
            .fwd,
        ) orelse break :blk false;
        break :blk try removeSingleLocated(graph, &endpoints, remove_state, source, destination, forward_found, false);
    };
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}

pub fn removeEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, edge_id: types.EdgeId) !bool {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    const remove_state = loadRemoveState(&endpoints);

    const forward_found = common.findSlotInAdjById(
        graph,
        remove_state.source_pub.first_block,
        remove_state.source_pub.block_count,
        remove_state.source_pub.group_count,
        remove_state.source_pub.first_group,
        destination.index,
        edge_id.local,
    ) orelse return false;
    const removed = try removeSingleLocated(graph, &endpoints, remove_state, source, destination, forward_found, false);
    if (!removed) return false;

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return removed;
}
