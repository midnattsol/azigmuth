const std = @import("std");
const adjacency = @import("../adjacency/mod.zig");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_published = @import("../storage/node/published.zig");

pub const TraversalState = struct {
    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,
};

pub const TinyState = struct {
    tiny_mode: bool,
    tiny_slot: u32,
    tiny_count: u16,
};

pub const CursorInit = struct {
    traversal: TraversalState,
    tiny: TinyState,
    group_count_bound: u16,
};

pub fn tinyState(side_adj: types.SideAdj) TinyState {
    return .{
        .tiny_mode = node_published.NodePublished.isTiny(&side_adj),
        .tiny_slot = side_adj.first_block,
        .tiny_count = if (node_published.NodePublished.isTiny(&side_adj)) node_published.NodePublished.tinyCount(&side_adj) else 0,
    };
}

pub fn buildCursorInit(side_adj: types.SideAdj) CursorInit {
    return .{
        .traversal = buildTraversalState(side_adj),
        .tiny = tinyState(side_adj),
        .group_count_bound = side_adj.group_count,
    };
}

fn blockLimitForSide(graph: *const graph_core.GraphCore, comptime side: adjacency.AdjSide) u32 {
    return switch (side) {
        .fwd => @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire),
        .rev => @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire),
    };
}

pub fn advanceTraversalBlock(iterator: anytype, graph: *const graph_core.GraphCore) ?u32 {
    while (iterator.blocks_remaining == 0) {
        if (!advanceToNextGroup(iterator, graph)) return null;
    }

    const block_idx = iterator.current_block_index;
    iterator.current_block_index += 1;
    iterator.blocks_remaining -= 1;
    return block_idx;
}

/// Builds the initial traversal state for contiguous or grouped side storage.
pub fn buildTraversalState(side_adj: types.SideAdj) TraversalState {
    if (side_adj.block_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = 0,
            .blocks_remaining = 0,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    if (node_published.NodePublished.isTiny(&side_adj)) {
        return .{
            .contiguous_mode = true,
            .current_block_index = 0,
            .blocks_remaining = 0,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    if (side_adj.group_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = side_adj.first_block,
            .blocks_remaining = side_adj.block_count,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    return .{
        .contiguous_mode = false,
        .current_block_index = 0,
        .blocks_remaining = 0,
        .current_group_index = side_adj.first_group,
    };
}

/// Performs a cheap bounds/layout check before iterating a published side.
pub fn validateReadSideQuick(
    graph: *const graph_core.GraphCore,
    side_adj: types.SideAdj,
    comptime side: adjacency.AdjSide,
) !void {
    if (node_published.NodePublished.isTiny(&side_adj)) {
        return adjacency.validateSideAdjLayoutForSide(graph, side_adj, side);
    }

    const block_limit = blockLimitForSide(graph, side);

    if (side_adj.block_count == 0) {
        if (side_adj.group_count != 0) return error.CorruptGraph;
        return;
    }

    if (side_adj.group_count == 0) {
        if (side_adj.first_block >= block_limit) return error.CorruptGraph;
        const end = std.math.add(u32, side_adj.first_block, side_adj.block_count) catch return error.CorruptGraph;
        if (end > block_limit) return error.CorruptGraph;
        return;
    }

    if (side_adj.first_group >= graph.group_count) return error.CorruptGraph;
}

/// Initializes a grouped traversal so the first block range is ready to consume.
pub fn primeGroupedTraversal(iterator: anytype, graph: *const graph_core.GraphCore) void {
    if (iterator.contiguous_mode) return;
    if (iterator.current_group_index == constants.END_OF_CHAIN) return;
    if (iterator.current_group_index >= graph.group_count) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return;
    }

    const first_group = page_ops.groupAtConst(graph, iterator.current_group_index);
    iterator.current_block_index = first_group.start;
    iterator.blocks_remaining = first_group.count;
}

/// Advances a grouped traversal to the next run of blocks.
/// Returns false when no further run is available.
pub fn advanceToNextGroup(iterator: anytype, graph: *const graph_core.GraphCore) bool {
    if (iterator.contiguous_mode) return false;
    if (iterator.current_group_index == constants.END_OF_CHAIN) return false;
    if (iterator.current_group_index >= graph.group_count) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return false;
    }

    if (iterator.groups_visited + 1 >= iterator.group_count_bound) {
        iterator.current_group_index = constants.END_OF_CHAIN;
        return false;
    }

    iterator.current_group_index += 1;
    iterator.groups_visited += 1;

    const next_group = page_ops.groupAtConst(graph, iterator.current_group_index);
    iterator.current_block_index = next_group.start;
    iterator.blocks_remaining = next_group.count;
    return true;
}

/// Loads the next non-empty block as a counted span: dense storage means
/// iteration is a plain [0, live) loop — no mask, no loop-carried bit math.
pub fn loadNextNeighborSpan(iterator: anytype, graph: *const graph_core.GraphCore) bool {
    while (true) {
        const block_idx = advanceTraversalBlock(iterator, graph) orelse return false;
        switch (iterator.direction) {
            .fwd => {
                const live = page_ops.blockLiveCount(graph, block_idx, .fwd);
                if (live == 0) continue;
                iterator.current_slot = 0;
                iterator.current_live = live;
                iterator.cached_fwd_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
                iterator.cached_rev_block = null;
            },
            .rev => {
                const live = page_ops.blockLiveCount(graph, block_idx, .rev);
                if (live == 0) continue;
                iterator.current_slot = 0;
                iterator.current_live = live;
                iterator.cached_rev_block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
                iterator.cached_fwd_block = null;
            },
        }
        return true;
    }
}

pub fn loadNextOutEdgeSpan(iterator: anytype, graph: *const graph_core.GraphCore) bool {
    while (true) {
        const block_idx = advanceTraversalBlock(iterator, graph) orelse return false;
        const live = page_ops.blockLiveCount(graph, block_idx, .fwd);
        if (live == 0) continue;

        iterator.current_slot = 0;
        iterator.current_live = live;
        iterator.cached_fwd_block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
        iterator.cached_fwd_ids = page_ops.edgeBlockFwdIdsAtConst(graph, block_idx);
        return true;
    }
}
