const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const node_access = @import("../core/node_access.zig");
const node_publication_mod = @import("../storage/node/publication.zig");
const node_adjacency_buffers_mod = @import("../storage/node/adjacency_buffers.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const adjacency = @import("mod.zig");
const rcu = @import("../concurrency/rcu.zig");
const publish_mod = @import("../mutation/publish.zig");
const scratch_mod = @import("../mutation/scratch.zig");
const side_segments = @import("segments.zig");

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

pub const SegmentDesc = side_segments.SegmentDesc;
pub const BlockCursor = side_segments.BlockCursor;

pub const sideAdjOfNode = adjacency.sideAdjOfNode;

pub fn writeSide(node_adj: *types.NodeAdj, comptime side: adjacency.AdjSide, side_view: types.SideAdj) void {
    switch (side) {
        .fwd => {
            node_adj.first_block_fwd = side_view.first_block;
            node_adj.block_count_fwd = side_view.block_count;
            node_adj.segment_count_fwd = side_view.segment_count;
            node_adj.first_segment_fwd = side_view.first_segment;
        },
        .rev => {
            node_adj.first_block_rev = side_view.first_block;
            node_adj.block_count_rev = side_view.block_count;
            node_adj.segment_count_rev = side_view.segment_count;
            node_adj.first_segment_rev = side_view.first_segment;
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
    ctx: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        try callback(graph, ctx, block_idx);
    }
}

pub fn forEachSlotInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const count = node_adjacency_buffers_mod.NodeAdjacencyBuffers.tinyCount(&side_adj);
        for (0..count) |slot| {
            try callback(graph, ctx, TINY_SLOT_TAG | side_adj.first_block, @as(u7, @intCast(slot)));
        }
        return;
    }

    var cursor = BlockCursor.init(side_adj);
    while (cursor.next(graph)) |block_idx| {
        // Clamp: a corrupt sidecar must surface as a validation finding, not
        // as an out-of-bounds crash inside shared traversal helpers.
        const alive_count = @min(page_ops.blockAliveCount(graph, block_idx, side), constants.EDGES_PER_BLOCK);
        for (0..alive_count) |slot| {
            try callback(graph, ctx, block_idx, @as(u7, @intCast(slot)));
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
        const tiny_slot_idx = block_idx & ~TINY_SLOT_TAG;
        return switch (side) {
            .fwd => page_ops.tinySlotAtConst(graph, tiny_slot_idx, .fwd).entries[slot].destination,
            .rev => page_ops.tinySlotAtConst(graph, tiny_slot_idx, .rev).sources[slot],
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
        const entry = page_ops.tinySlotAtConst(graph, block_idx & ~TINY_SLOT_TAG, .fwd).entries[slot];
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
    ctx: anytype,
    comptime callback: anytype,
) !void {
    if (side_adj.block_count == 0) return;

    try adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);

    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const count = node_adjacency_buffers_mod.NodeAdjacencyBuffers.tinyCount(&side_adj);
        switch (side) {
            .fwd => {
                const slot = page_ops.tinySlotAtConst(graph, side_adj.first_block, .fwd);
                for (0..count) |entry_idx| try callback(graph, ctx, slot.entries[entry_idx].destination);
            },
            .rev => {
                const slot = page_ops.tinySlotAtConst(graph, side_adj.first_block, .rev);
                for (0..count) |entry_idx| try callback(graph, ctx, slot.sources[entry_idx]);
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
        const alive_count = @min(page_ops.blockAliveCount(graph, block_idx, side), constants.EDGES_PER_BLOCK);
        const block = page_ops.edgeBlockAtConst(graph, block_idx, side);
        for (0..alive_count) |slot| {
            const node_id = switch (side) {
                .fwd => block.destinations[slot],
                .rev => block.sources[slot],
            };
            try callback(graph, ctx, node_id);
        }
    }
}

pub fn forEachForwardEntryInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    ctx: anytype,
    comptime callback: anytype,
) !void {
    try forEachSlotInSide(graph, side_adj, .fwd, ctx, struct {
        fn segment(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: @TypeOf(ctx),
            block_idx: u32,
            slot: u7,
        ) !void {
            try callback(inner_graph, inner_ctx, readForwardEntryAtSlot(inner_graph, block_idx, slot));
        }
    }.segment);
}

fn countAliveSlotsInBlock(
    graph: *const graph_core.GraphCore,
    total: *usize,
    block_idx: u32,
    comptime side: adjacency.AdjSide,
) !void {
    if ((block_idx & TINY_SLOT_TAG) != 0) {
        total.* += 1;
        return;
    }
    total.* += page_ops.blockAliveCount(graph, block_idx, side);
}

pub fn countLiveInSide(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !usize {
    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        return node_adjacency_buffers_mod.NodeAdjacencyBuffers.tinyCount(&side_adj);
    }

    var total: usize = 0;
    try forEachBlockInSide(graph, side_adj, side, &total, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_total: *usize,
            block_idx: u32,
        ) !void {
            try countAliveSlotsInBlock(inner_graph, inner_total, block_idx, side);
        }
    }.callback);
    return total;
}

pub const SideBuilder = side_segments.SideBuilder;

pub fn collectBlockList(
    graph: *const graph_core.GraphCore,
    published_side_adj: types.SideAdj,
    old_block_idx: ?u32,
    new_block_idx: ?u32,
    append_block_idx: ?u32,
    out: *std.ArrayList(u32),
) !void {
    try adjacency.validateSideAdjLayout(graph, published_side_adj);
    try side_segments.collectBlockList(graph, published_side_adj, old_block_idx, new_block_idx, append_block_idx, out);
}

pub fn buildSideFromBlocks(
    side_adj: *types.SideAdj,
    graph: *graph_core.GraphCore,
    blocks: []const u32,
    scratch: *scratch_mod.MutationScratch,
) !void {
    try side_segments.buildSideFromBlocks(side_adj, graph, blocks, scratch);
}

pub fn retireSide(
    graph: *graph_core.GraphCore,
    adj_before: types.NodeAdj,
    comptime side: adjacency.AdjSide,
) !void {
    const side_view = sideAdjOfNode(adj_before, side);
    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_view)) {
        rcu.retireTinySlot(graph, side_view.first_block, side);
        return;
    }
    try side_segments.retireSide(graph, side_view, side);
}

pub fn publishBothAdj(
    graph: *graph_core.GraphCore,
    node_id: types.NodeId,
    node_publication: *node_publication_mod.NodePublicationCell,
    node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers,
    adj: types.NodeAdj,
    fwd_degree: u32,
    rev_degree: u32,
    sorted_fwd: bool,
    sorted_rev: bool,
) void {
    const state = node_publication.loadPublicationState();
    node_access.writeStagingFwd(graph, node_id, state, .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .segment_count = adj.segment_count_fwd,
        .first_segment = adj.first_segment_fwd,
    });
    node_access.writeStagingRev(graph, node_id, state, .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .segment_count = adj.segment_count_rev,
        .first_segment = adj.first_segment_rev,
    });
    _ = publish_mod.publishStagedBoth(node_publication, node_adjacency_buffers, state, adj.flags, fwd_degree, rev_degree, sorted_fwd, sorted_rev);
}

pub fn publishRevAdj(
    graph: *graph_core.GraphCore,
    node_id: types.NodeId,
    node_publication: *node_publication_mod.NodePublicationCell,
    node_adjacency_buffers: *node_adjacency_buffers_mod.NodeAdjacencyBuffers,
    adj: types.NodeAdj,
    new_rev_degree: u32,
    sorted_rev: bool,
) void {
    const state = node_publication.loadPublicationState();
    const rev_delta: i23 = @intCast(@as(i64, @intCast(new_rev_degree)) - @as(i64, @intCast(node_access.publishedRevDegreeFromStateAtConst(graph, node_id, state))));
    node_access.writeStagingRev(graph, node_id, state, .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .segment_count = adj.segment_count_rev,
        .first_segment = adj.first_segment_rev,
    });
    _ = publish_mod.publishStagedRev(node_publication, node_adjacency_buffers, state, adj.flags.needs_repair_rev, rev_delta, sorted_rev);
}

pub fn retireSegmentSlots(graph: *graph_core.GraphCore, first_segment_idx: u32, segment_count: u16) void {
    if (segment_count == 0) return;
    rcu.retireSegmentSlots(graph, first_segment_idx, segment_count);
}

/// Searches forward adjacency for a specific (destination, edge_id) pair.
pub fn findSlotInAdjById(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u32,
    segment_count: u16,
    first_segment_idx: u32,
    destination_idx: u32,
    edge_id: u32,
) ?AdjSlot {
    if (!graph.multigraph_enabled) return null;
    if (block_count == 0) return null;

    const side_view: types.SideAdj = .{
        .first_block = first_block_idx,
        .block_count = block_count,
        .segment_count = segment_count,
        .first_segment = first_segment_idx,
    };

    adjacency.validateSideAdjLayoutForSide(graph, side_view, .fwd) catch return null;

    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_view)) {
        const slot = adjacency.findTinyForwardSlotById(graph, side_view, destination_idx, edge_id) orelse return null;
        return .{ .block_idx = first_block_idx, .slot = slot };
    }

    if (segment_count == 0) {
        const slot = adjacency.findForwardSlotByIdInRun(graph, first_block_idx, block_count, destination_idx, edge_id) orelse return null;
        return .{ .block_idx = slot.block_idx, .slot = slot.slot };
    }

    const end_segment = first_segment_idx + segment_count;
    for (first_segment_idx..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (adjacency.findForwardSlotByIdInRun(graph, segment.start, segment.count, destination_idx, edge_id)) |slot| {
            return .{ .block_idx = slot.block_idx, .slot = slot.slot };
        }
    }
    return null;
}

pub fn findSlotInAdj(
    graph: *const graph_core.GraphCore,
    first_block_idx: u32,
    block_count: u32,
    segment_count: u16,
    first_segment_idx: u32,
    target: u32,
    comptime side: adjacency.AdjSide,
    globally_sorted: bool,
) ?AdjSlot {
    if (block_count == 0) return null;

    const side_view: types.SideAdj = .{
        .first_block = first_block_idx,
        .block_count = block_count,
        .segment_count = segment_count,
        .first_segment = first_segment_idx,
    };

    if (node_adjacency_buffers_mod.NodeAdjacencyBuffers.isTiny(&side_view)) {
        switch (side) {
            .fwd => {
                const slot = page_ops.tinySlotAtConst(graph, first_block_idx, .fwd);
                const count = node_adjacency_buffers_mod.NodeAdjacencyBuffers.tinyCount(&side_view);
                for (0..count) |entry_idx| {
                    if (slot.entries[entry_idx].destination == target) {
                        return .{ .block_idx = first_block_idx, .slot = @intCast(entry_idx) };
                    }
                }
            },
            .rev => {
                const slot = page_ops.tinySlotAtConst(graph, first_block_idx, .rev);
                const count = node_adjacency_buffers_mod.NodeAdjacencyBuffers.tinyCount(&side_view);
                for (0..count) |entry_idx| {
                    if (slot.sources[entry_idx] == target) {
                        return .{ .block_idx = first_block_idx, .slot = @intCast(entry_idx) };
                    }
                }
            },
        }
        return null;
    }

    if (segment_count == 0) {
        return findSlotInBlockRun(graph, first_block_idx, block_count, target, side, globally_sorted);
    }

    const end_segment = first_segment_idx + segment_count;
    for (first_segment_idx..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        const segment = page_ops.edgeBlockSegmentAtConst(graph, segment_idx);
        if (findSlotInBlockRun(graph, segment.start, segment.count, target, side, globally_sorted)) |slot| return slot;
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
        const alive = page_ops.blockAliveCount(graph, block_idx, side);
        const slot = switch (side) {
            .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, alive, target),
            .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, alive, target),
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
        const alive = page_ops.blockAliveCount(graph, block_idx, side);
        if (alive == 0) break;
        const first_key = switch (side) {
            .fwd => block.destinations[0],
            .rev => block.sources[0],
        };
        const last_key = switch (side) {
            .fwd => block.destinations[alive - 1],
            .rev => block.sources[alive - 1],
        };
        if (target < first_key) {
            high = mid;
        } else if (target > last_key) {
            low = mid + 1;
        } else {
            const slot = switch (side) {
                .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, block, alive, target),
                .rev => adjacency.searchInBlock(types.EdgeBlockRev, block, alive, target),
            } orelse break;
            return .{ .block_idx = block_idx, .slot = slot };
        }
    }
    // A globally-sorted side makes the binary-search miss conclusive.
    if (globally_sorted) return null;
    return findSlotInBlockRunLinear(graph, start, count, target, side);
}
