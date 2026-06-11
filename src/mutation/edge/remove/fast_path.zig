const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const common = @import("../../common.zig");
const local_repair = @import("../../local_repair.zig");
const structural_rebuild = @import("../../structural_rebuild.zig");
const remove_finalize = @import("finalize.zig");

pub const RemovalPlan = struct {
    found: common.AdjSlot,
    live_before: u7,
};

pub const SingleRemovalPlans = struct {
    forward_plan: RemovalPlan,
    reverse_plan: RemovalPlan,
};

pub fn ensureForwardFastPathAllowedIfBlock(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    forward_found: ?common.AdjSlot,
) !void {
    if (node_published.NodePublished.isTiny(published_side)) return;
    const found = forward_found orelse return error.CorruptGraph;
    try ensureRemovalFastPathAllowed(graph, published_side, found, false);
}

pub fn planSingleRemoval(
    graph: *graph_core.GraphCore,
    source_pub: *const types.SideAdj,
    destination_pub: *const types.SideAdj,
    forward_found: common.AdjSlot,
    reverse_found: common.AdjSlot,
) !SingleRemovalPlans {
    return .{
        .forward_plan = try planRemovalSide(graph, source_pub, forward_found, .fwd),
        .reverse_plan = try planRemovalSide(graph, destination_pub, reverse_found, .rev),
    };
}

pub fn ensureSingleRemovalLocality(
    graph: *graph_core.GraphCore,
    source_pub: *const types.SideAdj,
    destination_pub: *const types.SideAdj,
    forward_found: common.AdjSlot,
    reverse_found: common.AdjSlot,
    allow_structural_rebuild: bool,
) !void {
    if (allow_structural_rebuild) return;
    if (source_pub.block_count > 1) {
        const source_tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, source_pub)) orelse return error.CorruptGraph;
        if (forward_found.block_idx != source_tail_idx) return error.RepairRequired;
    }
    if (destination_pub.block_count > 1) {
        const destination_tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, destination_pub)) orelse return error.CorruptGraph;
        if (reverse_found.block_idx != destination_tail_idx) return error.RepairRequired;
    }
}

pub fn applyRemovalPlanSide(
    graph: *graph_core.GraphCore,
    staging_side: *types.SideAdj,
    published_side: *const types.SideAdj,
    plan: RemovalPlan,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
    allow_structural_rebuild: bool,
) !remove_finalize.RemovalBuild {
    try ensureRemovalFastPathAllowed(graph, published_side, plan.found, allow_structural_rebuild);

    // The dropped slot's property row dies with the edge; retire it after
    // publish via the scratch list.
    if (side == .fwd and graph.edge_properties_enabled) {
        const removed_row = page_ops.edgeBlockFwdPropsAtConst(graph, plan.found.block_idx).rows[plan.found.slot];
        try scratch.markRetirePropRow(graph.allocator, removed_row);
    }

    const old_block = plan.found.block_idx;
    const new_block = try scratch.allocBlock(graph, side);
    if (new_block == old_block) return error.CorruptGraph;
    const new_live: u7 = switch (side) {
        .fwd => copyForwardBlockWithoutSlot(graph, old_block, new_block, plan.found.slot, plan.live_before),
        .rev => copyReverseBlockWithoutSlot(graph, old_block, new_block, plan.found.slot, plan.live_before),
    };

    if (published_side.block_count == 1) {
        if (new_live == 0) {
            staging_side.first_block = 0;
            staging_side.block_count = 0;
            staging_side.group_count = 0;
            staging_side.first_group = 0;
            return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
        }

        staging_side.first_block = new_block;
        staging_side.block_count = 1;
        staging_side.group_count = 0;
        staging_side.first_group = 0;
        return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
    }

    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, published_side)) orelse return error.CorruptGraph;
    if (plan.found.block_idx == tail_idx) {
        if (try local_repair.removeTailBlock(graph, staging_side, published_side, new_block, new_live, scratch)) {
            return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
        }
    }

    if (!allow_structural_rebuild) return error.RepairRequired;

    try structural_rebuild.rebuildAfterSingleRemoval(graph, staging_side, published_side, old_block, if (new_live > 0) new_block else null, side, scratch);

    return .{ .old_block = old_block, .new_block = new_block, .new_live = new_live };
}

pub fn planRemovalSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    found: common.AdjSlot,
    comptime side: adjacency.AdjSide,
) !RemovalPlan {
    const live_before: u7 = switch (side) {
        .fwd => @intCast(page_ops.blockLiveCount(graph, found.block_idx, .fwd)),
        .rev => @intCast(page_ops.blockLiveCount(graph, found.block_idx, .rev)),
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
    if (graph.edge_properties_enabled) {
        page_ops.edgeBlockFwdPropsAt(graph, new_block).* = page_ops.edgeBlockFwdPropsAtConst(graph, old_block).*;
    }

    const block = page_ops.edgeBlockAt(graph, new_block, .fwd);
    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block) else undefined;
    const prop_block = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, new_block) else undefined;
    var shift: u7 = slot;
    while (shift < live_before - 1) : (shift += 1) {
        block.destinations[shift] = block.destinations[shift + 1];
        block.relations[shift] = block.relations[shift + 1];
        block.flags[shift] = block.flags[shift + 1];
        if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift + 1];
        if (graph.edge_properties_enabled) prop_block.rows[shift] = prop_block.rows[shift + 1];
    }

    const new_live: u7 = live_before - 1;
    page_ops.setBlockLiveCount(graph, new_block, .fwd, @intCast(new_live));
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
    page_ops.setBlockLiveCount(graph, new_block, .rev, @intCast(new_live));
    return new_live;
}
