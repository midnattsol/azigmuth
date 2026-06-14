const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const node_access = @import("../core/node_access.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_published_mod = @import("../storage/node/published.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("mod.zig");
const rcu = @import("../concurrency/rcu.zig");
const publish_mod = @import("../mutation/publish.zig");
const scratch_mod = @import("../mutation/scratch.zig");
const side_runs = @import("runs.zig");

pub const AdjSlot = struct {
    block_idx: u32,
    slot: u7,
};

pub const ForwardEntryView = struct {
    block_idx: u32,
    slot: u7,
    destination: u32,
    relation: u16,
    flags: types.EdgeFlags,
    edge_id: u32,
    prop_row: u32 = 0,
};

pub const TINY_SLOT_TAG: u32 = 0x8000_0000;

pub const RunDesc = side_runs.RunDesc;
pub const BlockCursor = side_runs.BlockCursor;

pub const sideAdjOfNode = adjacency.sideAdjOfNode;

pub fn writeSide(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide, side_view: types.SideAdj) void {
    switch (side) {
        .fwd => {
            node_adj.first_block_fwd = side_view.first_block;
            node_adj.block_count_fwd = side_view.block_count;
            node_adj.group_count_fwd = side_view.group_count;
            node_adj.first_group_fwd = side_view.first_group;
        },
        .rev => {
            node_adj.first_block_rev = side_view.first_block;
            node_adj.block_count_rev = side_view.block_count;
            node_adj.group_count_rev = side_view.group_count;
            node_adj.first_group_rev = side_view.first_group;
        },
    }
}

pub fn nodeAdjForSide(side_view: types.SideAdj, flags: types.NodeFlags, comptime side: adjacency.AdjSide) types.NodeAdj {
    var node_adj = std.mem.zeroes(types.NodeAdj);
    node_adj.flags = flags;
    writeSide(&node_adj, side, side_view);
    return node_adj;
}

pub fn forEachBlockInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        try callback(graph, context, block_idx);
    }
}

pub fn forEachSlotInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    if (node_published_mod.NodePublished.isTiny(&side_adj)) {
        const count = node_published_mod.NodePublished.tinyCount(&side_adj);
        for (0..count) |slot| {
            try callback(graph, context, TINY_SLOT_TAG | side_adj.first_block, @as(u7, @intCast(slot)));
        }
        return;
    }

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        // Clamp: a corrupt sidecar must surface as a validation finding, not
        // as an out-of-bounds crash inside shared traversal helpers.
        const live_count = @min(page_ops.blockLiveCount(graph, block_idx, side), constants.EDGES_PER_BLOCK);
        for (0..live_count) |slot| {
            try callback(graph, context, block_idx, @as(u7, @intCast(slot)));
        }
    }
}

pub fn readNodeIdAtSlot(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    comptime side: adjacency.AdjSide,
) u32 {
    if ((block_idx & TINY_SLOT_TAG) != 0) {
        const tiny_block_idx = block_idx & ~TINY_SLOT_TAG;
        return switch (side) {
            .fwd => page_ops.tinyBlockAtConst(graph, tiny_block_idx, .fwd).entries[slot].destination,
            .rev => page_ops.tinyBlockAtConst(graph, tiny_block_idx, .rev).sources[slot],
        };
    }

    const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
    return switch (side) {
        .fwd => block.destinations[slot],
        .rev => block.sources[slot],
    };
}

pub fn readNodeIdAtSlotDynamic(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
    side: adjacency.AdjSide,
) u32 {
    return switch (side) {
        .fwd => readNodeIdAtSlot(graph, block_idx, slot, .fwd),
        .rev => readNodeIdAtSlot(graph, block_idx, slot, .rev),
    };
}

pub fn readForwardEntryAtSlot(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    slot: u7,
) ForwardEntryView {
    if ((block_idx & TINY_SLOT_TAG) != 0) {
        const tagged_block_idx = block_idx;
        const entry = page_ops.tinyBlockAtConst(graph, block_idx & ~TINY_SLOT_TAG, .fwd).entries[slot];
        return .{
            .block_idx = tagged_block_idx,
            .slot = slot,
            .destination = entry.destination,
            .relation = entry.relation,
            .flags = entry.flags,
            .edge_id = entry.edge_id,
            .prop_row = entry.prop_row,
        };
    }

    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    return .{
        .block_idx = block_idx,
        .slot = slot,
        .destination = block.destinations[slot],
        .relation = block.relations[slot],
        .flags = @bitCast(block.flags[slot]),
        .edge_id = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAtConst(graph, block_idx).ids[slot] else 0,
        .prop_row = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAtConst(graph, block_idx).rows[slot] else 0,
    };
}

pub fn forEachNodeIdInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    context: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    if (node_published_mod.NodePublished.isTiny(&side_adj)) {
        const count = node_published_mod.NodePublished.tinyCount(&side_adj);
        switch (side) {
            .fwd => {
                const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
                for (0..count) |entry_idx| try callback(graph, context, slot.entries[entry_idx].destination);
            },
            .rev => {
                const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev);
                for (0..count) |entry_idx| try callback(graph, context, slot.sources[entry_idx]);
            },
        }
        return;
    }

    // The block pointer is resolved once per block instead of once per slot,
    // so the inner loop never re-walks the page directory.
    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        // Clamp: a corrupt sidecar must surface as a validation finding, not
        // as an out-of-bounds crash inside shared traversal helpers.
        const live_count = @min(page_ops.blockLiveCount(graph, block_idx, side), constants.EDGES_PER_BLOCK);
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        for (0..live_count) |slot| {
            const node_id = switch (side) {
                .fwd => block.destinations[slot],
                .rev => block.sources[slot],
            };
            try callback(graph, context, node_id);
        }
    }
}

pub fn forEachForwardEntryInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    context: anytype,
    comptime callback: anytype,
) !void {
    try forEachSlotInSide(graph, side_adj, .fwd, context, struct {
        fn run(
            inner_graph: *const graph_core.GraphCore,
            inner_context: @TypeOf(context),
            block_idx: u32,
            slot: u7,
        ) !void {
            try callback(inner_graph, inner_context, readForwardEntryAtSlot(inner_graph, block_idx, slot));
        }
    }.run);
}

fn countLiveSlotsInBlock(
    graph: *const graph_core.GraphCore,
    total: *usize,
    block_idx: u32,
    comptime side: adjacency.AdjSide,
) !void {
    if ((block_idx & TINY_SLOT_TAG) != 0) {
        total.* += 1;
        return;
    }
    total.* += page_ops.blockLiveCount(graph, block_idx, side);
}

pub fn countLiveInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !usize {
    if (node_published_mod.NodePublished.isTiny(&side_adj)) {
        return node_published_mod.NodePublished.tinyCount(&side_adj);
    }

    var total: usize = 0;
    try forEachBlockInSide(graph, side_adj, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *usize,
            block_idx: u32,
        ) !void {
            try countLiveSlotsInBlock(inner_graph, inner_total, block_idx, side);
        }
    }.callback);
    return total;
}

pub const SideBuilder = side_runs.SideBuilder;

pub fn collectBlockList(
    graph: *const graph_core.GraphCore,
    published_side_adj: types.SideAdj,
    old_block_idx: ?u32,
    new_block_idx: ?u32,
    append_block_idx: ?u32,
    out: *std.ArrayList(u32),
) !void {
    try adjacency.validateSideAdjLayout(graph, published_side_adj);
    try side_runs.collectBlockList(graph, published_side_adj, old_block_idx, new_block_idx, append_block_idx, out);
}

pub fn buildSideFromBlocks(
    side_adj: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *scratch_mod.MutationScratch,
) !void {
    try side_runs.buildSideFromBlocks(side_adj, graph, blocks, scratch);
}

pub fn retireSide(
    graph: *graph_core.GraphCore,
    adj_before: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const side_view = sideAdjOfNode(adj_before, side);
    if (node_published_mod.NodePublished.isTiny(&side_view)) {
        rcu.retireTinyBlock(graph, side_view.first_block, side);
        return;
    }
    try side_runs.retireSide(graph, side_view, side);
}

pub fn publishBothAdj(
    graph: *graph_core.GraphCore,
    node_id: types.NodeId,
    node_meta: *node_meta_mod.NodeMeta,
    node_published: *node_published_mod.NodePublished,
    adj: types.NodeAdj,
    fwd_degree: u32,
    rev_degree: u32,
    fwd_sorted: bool,
    rev_sorted: bool,
) void {
    const meta = node_meta.loadPublishedMeta();
    node_access.writeStagingFwd(graph, node_id, meta, .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    });
    node_access.writeStagingRev(graph, node_id, meta, .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    });
    _ = publish_mod.publishStagedBoth(node_meta, node_published, meta, adj.flags, fwd_degree, rev_degree, fwd_sorted, rev_sorted);
}

pub fn publishRevAdj(
    graph: *graph_core.GraphCore,
    node_id: types.NodeId,
    node_meta: *node_meta_mod.NodeMeta,
    node_published: *node_published_mod.NodePublished,
    adj: types.NodeAdj,
    new_rev_degree: u32,
    rev_sorted: bool,
) void {
    const meta = node_meta.loadPublishedMeta();
    const rev_delta: i23 = @intCast(@as(i64, @intCast(new_rev_degree)) - @as(i64, @intCast(node_access.publishedRevDegreeFromMetaAtConst(graph, node_id, meta))));
    node_access.writeStagingRev(graph, node_id, meta, .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    });
    _ = publish_mod.publishStagedRev(node_meta, node_published, meta, adj.flags.needs_repair_rev, rev_delta, rev_sorted);
}

pub fn retireGroupChain(graph: *graph_core.GraphCore, first_group_idx: u32, group_count: u16) void {
    if (group_count == 0) return;
    rcu.retireGroupSpan(graph, first_group_idx, group_count);
}

/// Searches forward adjacency for a specific (destination, edge_id) pair.
pub fn findSlotInAdjById(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u32,
    group_count: u16,
    first_group_idx: u32,
    destination_idx: u32,
    edge_id: u32,
) ?AdjSlot {
    if (!graph.multigraph_enabled) return null;
    if (block_count == 0) return null;

    const side_view: types.SideAdj = .{
        .first_block = first_block_idx,
        .block_count = block_count,
        .group_count = group_count,
        .first_group = first_group_idx,
    };

    adjacency.validateSideAdjLayoutForSide(graph, side_view, .fwd) catch return null;

    if (node_published_mod.NodePublished.isTiny(&side_view)) {
        const slot = adjacency.findTinyForwardSlotById(graph, side_view, destination_idx, edge_id) orelse return null;
        return .{ .block_idx = first_block_idx, .slot = slot };
    }

    if (group_count == 0) {
        const slot = adjacency.findForwardSlotByIdInRun(graph, first_block_idx, block_count, destination_idx, edge_id) orelse return null;
        return .{ .block_idx = slot.block_idx, .slot = slot.slot };
    }

    const end_group = first_group_idx + group_count;
    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        if (adjacency.findForwardSlotByIdInRun(graph, group.start, group.count, destination_idx, edge_id)) |slot| {
            return .{ .block_idx = slot.block_idx, .slot = slot.slot };
        }
    }
    return null;
}

pub fn findSlotInAdj(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u32,
    group_count: u16,
    first_group_idx: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
    globally_sorted: bool,
) ?AdjSlot {
    if (block_count == 0) return null;

    const side_view: types.SideAdj = .{
        .first_block = first_block_idx,
        .block_count = block_count,
        .group_count = group_count,
        .first_group = first_group_idx,
    };

    if (node_published_mod.NodePublished.isTiny(&side_view)) {
        switch (side) {
            .fwd => {
                const slot = page_ops.tinyBlockAtConst(graph, first_block_idx, .fwd);
                const count = node_published_mod.NodePublished.tinyCount(&side_view);
                for (0..count) |entry_idx| {
                    if (slot.entries[entry_idx].destination == target) {
                        return .{ .block_idx = first_block_idx, .slot = @intCast(entry_idx) };
                    }
                }
            },
            .rev => {
                const slot = page_ops.tinyBlockAtConst(graph, first_block_idx, .rev);
                const count = node_published_mod.NodePublished.tinyCount(&side_view);
                for (0..count) |entry_idx| {
                    if (slot.sources[entry_idx] == target) {
                        return .{ .block_idx = first_block_idx, .slot = @intCast(entry_idx) };
                    }
                }
            },
        }
        return null;
    }

    if (group_count == 0) {
        return findSlotInBlockRun(graph, first_block_idx, block_count, target, side, globally_sorted);
    }

    const end_group = first_group_idx + group_count;
    for (first_group_idx..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        const group = page_ops.edgeBlockGroupAtConst(graph, group_idx);
        if (findSlotInBlockRun(graph, group.start, group.count, target, side, globally_sorted)) |slot| return slot;
    }
    return null;
}

fn findSlotInBlockRunLinear(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
) ?AdjSlot {
    for (start..start + count) |block_idx_usize| {
        const block_idx: u32 = @intCast(block_idx_usize);
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        const live = page_ops.blockLiveCount(graph, block_idx, side);
        const slot = switch (side) {
            .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, live, target),
            .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, live, target),
        } orelse continue;
        return .{ .block_idx = block_idx, .slot = slot };
    }
    return null;
}

fn findSlotInBlockRun(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
    globally_sorted: bool,
) ?AdjSlot {
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid: u32 = low + (high - low) / 2;
        const block_idx = start + mid;
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        const live = page_ops.blockLiveCount(graph, block_idx, side);
        if (live == 0) break;
        const first_key = switch (side) {
            .fwd => block.destinations[0],
            .rev => block.sources[0],
        };
        const last_key = switch (side) {
            .fwd => block.destinations[live - 1],
            .rev => block.sources[live - 1],
        };
        if (target < first_key) {
            high = mid;
        } else if (target > last_key) {
            low = mid + 1;
        } else {
            const slot = switch (side) {
                .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, live, target),
                .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, live, target),
            } orelse break;
            return .{ .block_idx = block_idx, .slot = slot };
        }
    }
    // A globally-sorted side makes the binary-search miss conclusive.
    if (globally_sorted) return null;
    return findSlotInBlockRunLinear(graph, start, count, target, side);
}
