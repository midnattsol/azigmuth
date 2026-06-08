const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const repair = @import("../../maintenance/repair.zig");
const common = @import("../common.zig");
const shared = @import("shared.zig");
const local_side_edit = @import("../local_side_edit.zig");
const structural_rebuild = @import("../structural_rebuild.zig");

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

const RemovalStaging = struct {
    source_staging: *types.SideAdj,
    destination_staging: *types.SideAdj,
};

const SingleRemovalPlans = struct {
    forward_plan: RemovalPlan,
    reverse_plan: RemovalPlan,
};

const SingleRemovalBuilds = struct {
    source_build: RemovalBuild,
    destination_build: RemovalBuild,
};

const RemovalPublishAdj = struct {
    source_publish_adj: types.NodeAdj,
    destination_publish_adj: types.NodeAdj,
};

const BulkRemovalResult = struct {
    removed: u32,
    publish_adj: RemovalPublishAdj,
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

fn publishBulkRemoved(
    endpoints: *const shared.EndpointState,
    source: types.NodeId,
    destination: types.NodeId,
    removed: u32,
    publish_adj: RemovalPublishAdj,
) void {
    if (source.index == destination.index) {
        var merged_flags = publish_adj.source_publish_adj.flags;
        merged_flags.needs_repair_rev = publish_adj.destination_publish_adj.flags.needs_repair_rev;
        merged_flags.removed = false;
        _ = common.publishBothDelta(
            endpoints.source_node,
            endpoints.source_meta,
            merged_flags,
            -@as(i23, @intCast(removed)),
            -@as(i23, @intCast(removed)),
        );
        return;
    }

    _ = common.publishStagedRev(
        endpoints.destination_node,
        endpoints.destination_meta,
        publish_adj.destination_publish_adj.flags.needs_repair_rev,
        -@as(i23, @intCast(removed)),
    );
    _ = common.publishStagedFwd(
        endpoints.source_node,
        endpoints.source_meta,
        publish_adj.source_publish_adj.flags.needs_repair_fwd,
        -@as(i23, @intCast(removed)),
    );
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

fn retireBulkRemovedSides(
    graph: *graph_core.GraphCore,
    remove_state: RemoveState,
    endpoints: *const shared.EndpointState,
) !void {
    try common.retireSide(graph, common.nodeAdjForSide(remove_state.source_pub, endpoints.source_flags, .fwd), .fwd);
    try common.retireSide(graph, common.nodeAdjForSide(remove_state.destination_pub, endpoints.destination_flags, .rev), .rev);
}

fn prepareRemovalStaging(endpoints: *const shared.EndpointState) RemovalStaging {
    endpoints.source_node.copyPublishedToStagingFwd(endpoints.source_meta);
    endpoints.destination_node.copyPublishedToStagingRev(endpoints.destination_meta);
    return .{
        .source_staging = endpoints.source_node.stagingFwd(endpoints.source_meta),
        .destination_staging = endpoints.destination_node.stagingRev(endpoints.destination_meta),
    };
}

fn beginRemovalScratch() common.MutationScratch {
    return .{};
}

fn finalizeSingleRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    remove_state: RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    builds: SingleRemovalBuilds,
    publish_adj: RemovalPublishAdj,
) !bool {
    scratch.disarm();
    try publishRemoved(endpoints, source, destination, publish_adj.source_publish_adj, publish_adj.destination_publish_adj);
    try retireRemoved(graph, remove_state, builds.source_build, builds.destination_build);
    _ = graph.edge_count.fetchSub(1, .release);
    return true;
}

fn finalizeBulkRemoval(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    endpoints: *const shared.EndpointState,
    remove_state: RemoveState,
    source: types.NodeId,
    destination: types.NodeId,
    result: BulkRemovalResult,
) !bool {
    scratch.disarm();
    publishBulkRemoved(endpoints, source, destination, result.removed, result.publish_adj);
    try retireBulkRemovedSides(graph, remove_state, endpoints);
    _ = graph.edge_count.fetchSub(result.removed, .release);
    return true;
}

fn findReverseMatchForSingleRemoval(
    graph: *graph_core.GraphCore,
    remove_state: *const RemoveState,
    source: types.NodeId,
) !common.AdjSlot {
    return common.findSlotInAdj(
        graph,
        remove_state.destination_pub.first_block,
        remove_state.destination_pub.block_count,
        remove_state.destination_pub.group_count,
        remove_state.destination_pub.first_group,
        source.index,
        .rev,
    ) orelse error.CorruptGraph;
}

fn planSingleRemoval(
    graph: *graph_core.GraphCore,
    remove_state: *const RemoveState,
    forward_found: common.AdjSlot,
    reverse_found: common.AdjSlot,
) !SingleRemovalPlans {
    return .{
        .forward_plan = try planRemovalSide(graph, &remove_state.source_pub, forward_found, .fwd),
        .reverse_plan = try planRemovalSide(graph, &remove_state.destination_pub, reverse_found, .rev),
    };
}

fn ensureSingleRemovalLocality(
    graph: *graph_core.GraphCore,
    remove_state: *const RemoveState,
    forward_found: common.AdjSlot,
    reverse_found: common.AdjSlot,
    allow_structural_rebuild: bool,
) !void {
    if (allow_structural_rebuild) return;
    if (!try local_side_edit.isRemovalLocal(graph, &remove_state.source_pub, forward_found.block_idx)) return error.RepairRequired;
    if (!try local_side_edit.isRemovalLocal(graph, &remove_state.destination_pub, reverse_found.block_idx)) return error.RepairRequired;
}

fn applySingleRemoval(
    graph: *graph_core.GraphCore,
    staging: RemovalStaging,
    remove_state: *const RemoveState,
    plans: SingleRemovalPlans,
    scratch: *common.MutationScratch,
    allow_structural_rebuild: bool,
) !SingleRemovalBuilds {
    return .{
        .source_build = try applyRemovalPlanSide(graph, staging.source_staging, &remove_state.source_pub, plans.forward_plan, .fwd, scratch, allow_structural_rebuild),
        .destination_build = try applyRemovalPlanSide(graph, staging.destination_staging, &remove_state.destination_pub, plans.reverse_plan, .rev, scratch, allow_structural_rebuild),
    };
}

fn updateSingleRemovalDebt(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    staging: RemovalStaging,
    source: types.NodeId,
    destination: types.NodeId,
) RemovalPublishAdj {
    var source_publish_adj = common.nodeAdjForSide(staging.source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    var destination_publish_adj = common.nodeAdjForSide(staging.destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    return .{
        .source_publish_adj = source_publish_adj,
        .destination_publish_adj = destination_publish_adj,
    };
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
    const reverse_found = try findReverseMatchForSingleRemoval(graph, &remove_state, source);
    const plans = try planSingleRemoval(graph, &remove_state, forward_found, reverse_found);
    try ensureSingleRemovalLocality(graph, &remove_state, forward_found, reverse_found, allow_structural_rebuild);

    const staging = prepareRemovalStaging(endpoints);

    var scratch = beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const builds = try applySingleRemoval(graph, staging, &remove_state, plans, &scratch, allow_structural_rebuild);
    const publish_adj = updateSingleRemovalDebt(graph, endpoints, staging, source, destination);

    return finalizeSingleRemoval(graph, &scratch, endpoints, remove_state, source, destination, builds, publish_adj);
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

    const staging = prepareRemovalStaging(endpoints);

    var scratch = beginRemovalScratch();
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const result = try rebuildBulkRemovalSides(graph, endpoints, remove_state, staging, source, destination, &scratch);
    return finalizeBulkRemoval(graph, &scratch, endpoints, remove_state, source, destination, result);
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

fn ensureRemovalFastPathAllowed(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    found: common.AdjSlot,
    allow_structural_rebuild: bool,
) !void {
    if (allow_structural_rebuild) return;

    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, published_side)) orelse return error.CorruptGraph;
    if (published_side.block_count > 1 and found.block_idx != tail_idx) return error.RepairRequired;
}

fn copyForwardBlockWithoutSlot(
    graph: *graph_core.GraphCore,
    old_block: u32,
    new_block: u32,
    slot: u7,
    live_before: u7,
) u7 {
    const block_before = page_ops.edgeBlockAtConst(graph, old_block, .fwd);
    page_ops.edgeBlockAt(graph, new_block, .fwd).* = block_before.*;
    if (graph.multigraph_enabled) {
        const ids_before = page_ops.edgeBlockFwdIdsAtConst(graph, old_block);
        page_ops.edgeBlockFwdIdsAt(graph, new_block).* = ids_before.*;
    }

    const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block) else undefined;
    var shift: u7 = slot;
    while (shift < live_before - 1) : (shift += 1) {
        block.edges[shift] = block.edges[shift + 1];
        if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift + 1];
    }

    const new_live: u7 = live_before - 1;
    block.mask = constants.denseMask(@intCast(new_live));
    return new_live;
}

fn copyReverseBlockWithoutSlot(
    graph: *graph_core.GraphCore,
    old_block: u32,
    new_block: u32,
    slot: u7,
    live_before: u7,
) u7 {
    const block_before = page_ops.edgeBlockAtConst(graph, old_block, .rev);
    page_ops.edgeBlockAt(graph, new_block, .rev).* = block_before.*;

    const block = page_ops.edgeBlockAt(graph, new_block, .rev);
    var shift: u7 = slot;
    while (shift < live_before - 1) : (shift += 1) block.sources[shift] = block.sources[shift + 1];

    const new_live: u7 = live_before - 1;
    block.mask = constants.denseMask(@intCast(new_live));
    return new_live;
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
    try ensureRemovalFastPathAllowed(graph, published_side, plan.found, allow_structural_rebuild);

    const old_block = plan.found.block_idx;
    const new_block = try scratch.allocBlock(graph, side);
    if (new_block == old_block) return error.CorruptGraph;
    const new_live: u7 = switch (side) {
        .fwd => copyForwardBlockWithoutSlot(graph, old_block, new_block, plan.found.slot, plan.live_before),
        .rev => copyReverseBlockWithoutSlot(graph, old_block, new_block, plan.found.slot, plan.live_before),
    };

    if (try local_side_edit.tryApplyRemovalPlanFast(graph, staging_side, published_side, plan.found.block_idx, new_block, new_live, scratch)) {
        return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
    }

    if (!allow_structural_rebuild) return error.RepairRequired;

    try structural_rebuild.rebuildAfterSingleRemoval(graph, staging_side, published_side, old_block, if (new_live > 0) new_block else null, scratch);

    return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
}

fn cloneForwardBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .fwd);
    page_ops.edgeBlockAt(graph, new_block_idx, .fwd).* = page_ops.edgeBlockAtConst(graph, block_idx, .fwd).*;
    if (graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(graph, new_block_idx).* = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).*;
    }
    return new_block_idx;
}

fn cloneReverseBlock(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_idx: u32,
) !u32 {
    const new_block_idx = try scratch.allocBlock(graph, .rev);
    page_ops.edgeBlockAt(graph, new_block_idx, .rev).* = page_ops.edgeBlockAtConst(graph, block_idx, .rev).*;
    return new_block_idx;
}

fn appendForwardBlockWithoutDestination(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
    destination_idx: u32,
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
        try block_list.append(graph.allocator, try cloneForwardBlock(graph, scratch, block_idx));
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

fn appendReverseBlockRemovingSourceCount(
    graph: *graph_core.GraphCore,
    scratch: *common.MutationScratch,
    block_list: *std.ArrayList(u32),
    block_idx: u32,
    source_idx: u32,
    remove_count: u32,
) !u32 {
    const old_block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const live = @popCount(old_block.mask);
    if (live == 0) return remove_count;
    if (remove_count == 0) {
        try block_list.append(graph.allocator, try cloneReverseBlock(graph, scratch, block_idx));
        return 0;
    }

    var in_block: u32 = 0;
    for (0..live) |slot| {
        if (old_block.sources[slot] == source_idx) in_block += 1;
    }
    if (in_block == 0) {
        try block_list.append(graph.allocator, try cloneReverseBlock(graph, scratch, block_idx));
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

fn collectForwardRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ForwardRemovalContext,
    block_idx: u32,
) !void {
    context.removed += try appendForwardBlockWithoutDestination(@constCast(graph), context.scratch, context.block_list, block_idx, context.destination_idx);
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

fn collectReverseRemovalBlock(
    graph: *const graph_core.GraphCore,
    context: *ReverseRemovalContext,
    block_idx: u32,
) !void {
    context.remaining = try appendReverseBlockRemovingSourceCount(
        @constCast(graph),
        context.scratch,
        context.block_list,
        block_idx,
        context.source_idx,
        context.remaining,
    );
}

fn rebuildBulkRemovalSides(
    graph: *graph_core.GraphCore,
    endpoints: *const shared.EndpointState,
    remove_state: RemoveState,
    staging: RemovalStaging,
    source: types.NodeId,
    destination: types.NodeId,
    scratch: *common.MutationScratch,
) !BulkRemovalResult {
    const forward_result = try rebuildForwardRemoveAll(graph, &remove_state.source_pub, destination.index, scratch);
    if (forward_result.removed <= 1) return error.CorruptGraph;

    staging.source_staging.* = forward_result.new_side;
    staging.destination_staging.* = try rebuildReverseRemoveCount(graph, &remove_state.destination_pub, source.index, forward_result.removed, scratch);

    var source_publish_adj = common.nodeAdjForSide(staging.source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebt(graph, &source_publish_adj, source.index, .fwd);

    var destination_publish_adj = common.nodeAdjForSide(staging.destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebt(graph, &destination_publish_adj, destination.index, .rev);

    return .{
        .removed = forward_result.removed,
        .publish_adj = .{
            .source_publish_adj = source_publish_adj,
            .destination_publish_adj = destination_publish_adj,
        },
    };
}

/// Removes one edge from `source` to `destination`.
/// Returns false when no matching edge exists.
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

/// Removes one multigraph edge identified by `(destination, edge_id)`.
/// Returns false when no matching edge exists.
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
