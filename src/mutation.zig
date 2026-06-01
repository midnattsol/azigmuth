//! Edge insertion and removal — the mutable core of the graph engine.
//!
//! Both `addEdge` and `removeEdge` follow the same RCU + COW pattern:
//!   1. Read published adjacency and locate the affected block(s).
//!   2. Copy published `NodeAdj` into the staging slot.
//!   3. Allocate COW copies of the affected blocks.
//!   4. Mutate the copies (insert or delete).
//!   5. Rebuild the staging adjacency to point to the new blocks.
//!   6. Publish reverse first, then forward.
//!   7. Retire old blocks, bump epoch, reclaim safe blocks.
//!   8. Update `edge_count`.

const constants = @import("constants.zig");
const graph = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");
const repair = @import("repair.zig");

/// Adds a directed edge `src → dest` with a relation label and flags.
///
/// Fails with:
///   - `InvalidNode` if either endpoint does not exist.
///   - `EdgeAlreadyExists` if the edge is already present (non-multigraph mode).
///
/// Follows the RCU + COW mutation model (see module doc).
pub fn addEdge(core: *graph.GraphCore, src: types.NodeId, dest: types.NodeId, relation: u16, flags: u16) !void {
    if (src.index >= core.node_count or dest.index >= core.node_count) return error.InvalidNode;

    var src_node = page_ops.nodeAt(core, src);
    const src_published_adj_index: u1 = src_node.loadPublishedAdjIndex();
    const src_staging_adj_index: u1 = 1 - src_published_adj_index;
    src_node.copyPublishedToStaging();
    const src_adj = &src_node.adj_buffers[src_staging_adj_index];

    var dst_node = page_ops.nodeAt(core, dest);
    const dst_published_adj_index: u1 = dst_node.loadPublishedAdjIndex();
    const dst_staging_adj_index: u1 = 1 - dst_published_adj_index;
    dst_node.copyPublishedToStaging();
    const dst_adj = &dst_node.adj_buffers[dst_staging_adj_index];

    if (adjacency.hasEdgeInAdj(core, src_node.adj_buffers[src_published_adj_index], dest.index)) {
        return error.EdgeAlreadyExists;
    }

    var old_block_fwd: ?u32 = null;
    var block_fwd_idx: u32 = undefined;
    if (src_adj.block_count_fwd == 0) {
        block_fwd_idx = try page_ops.allocBlock(core, .fwd);
        src_adj.first_block_fwd = block_fwd_idx;
        src_adj.block_count_fwd = 1;
    } else {
        const tail = adjacency.tailBlockIndex(core, src_adj, .fwd);
        const tail_block = page_ops.edgeBlockAt(core, tail, .fwd);
        const live = @popCount(tail_block.mask);
        if (live == 64) {
            block_fwd_idx = try page_ops.allocBlock(core, .fwd);
            if (block_fwd_idx == tail + 1) {
                if (src_adj.group_count_fwd > 0) {
                    adjacency.extendTailGroup(core, src_adj, .fwd);
                }
                src_adj.block_count_fwd += 1;
            } else {
                try adjacency.appendGroupToAdj(core, src_adj, block_fwd_idx, .fwd);
                src_adj.block_count_fwd += 1;
            }
        } else {
            old_block_fwd = tail;
            block_fwd_idx = try page_ops.allocBlock(core, .fwd);
            page_ops.edgeBlockAt(core, block_fwd_idx, .fwd).* = tail_block.*;

            if (src_adj.block_count_fwd == 1) {
                src_adj.first_block_fwd = block_fwd_idx;
            } else {
                const was_contiguous = src_adj.group_count_fwd == 0;
                adjacency.removeTailFromAdj(core, src_adj, .fwd);
                try adjacency.appendGroupToAdj(core, src_adj, block_fwd_idx, .fwd);
                if (was_contiguous) src_adj.block_count_fwd += 1;
            }
        }
    }

    {
        const fwd_block = page_ops.edgeBlockAt(core, block_fwd_idx, .fwd);
        const live = @popCount(fwd_block.mask);
        var insertion_point: u7 = 0;
        var search_end: u7 = @intCast(live);
        while (insertion_point < search_end) {
            const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
            if (fwd_block.edges[probe].dest < dest.index) {
                insertion_point = probe + 1;
            } else if (fwd_block.edges[probe].dest == dest.index) {
                return error.EdgeAlreadyExists;
            } else {
                search_end = probe;
            }
        }
        var shift: u7 = @intCast(live);
        while (shift > insertion_point) {
            fwd_block.edges[shift] = fwd_block.edges[shift - 1];
            shift -= 1;
        }
        fwd_block.edges[insertion_point] = types.Edge{ .dest = dest.index, .relation = relation, .flags = @bitCast(flags) };
        fwd_block.mask = constants.denseMask(@intCast(live + 1));
    }

    var old_block_rev: ?u32 = null;
    var block_rev_idx: u32 = undefined;
    if (dst_adj.block_count_rev == 0) {
        block_rev_idx = try page_ops.allocBlock(core, .rev);
        dst_adj.first_block_rev = block_rev_idx;
        dst_adj.block_count_rev = 1;
    } else {
        const tail = adjacency.tailBlockIndex(core, dst_adj, .rev);
        const tail_block = page_ops.edgeBlockAt(core, tail, .rev);
        const live = @popCount(tail_block.mask);
        if (live == 64) {
            block_rev_idx = try page_ops.allocBlock(core, .rev);
            if (block_rev_idx == tail + 1) {
                if (dst_adj.group_count_rev > 0) {
                    adjacency.extendTailGroup(core, dst_adj, .rev);
                }
                dst_adj.block_count_rev += 1;
            } else {
                try adjacency.appendGroupToAdj(core, dst_adj, block_rev_idx, .rev);
                dst_adj.block_count_rev += 1;
            }
        } else {
            old_block_rev = tail;
            block_rev_idx = try page_ops.allocBlock(core, .rev);
            page_ops.edgeBlockAt(core, block_rev_idx, .rev).* = tail_block.*;
            if (dst_adj.block_count_rev == 1) {
                dst_adj.first_block_rev = block_rev_idx;
            } else {
                const was_contiguous = dst_adj.group_count_rev == 0;
                adjacency.removeTailFromAdj(core, dst_adj, .rev);
                try adjacency.appendGroupToAdj(core, dst_adj, block_rev_idx, .rev);
                if (was_contiguous) dst_adj.block_count_rev += 1;
            }
        }
    }

    {
        const rev_block = page_ops.edgeBlockAt(core, block_rev_idx, .rev);
        const live = @popCount(rev_block.mask);
        var insertion_point: u7 = 0;
        var search_end: u7 = @intCast(live);
        while (insertion_point < search_end) {
            const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
            if (rev_block.sources[probe] < src.index) {
                insertion_point = probe + 1;
            } else {
                search_end = probe;
            }
        }
        var shift: u7 = @intCast(live);
        while (shift > insertion_point) {
            rev_block.sources[shift] = rev_block.sources[shift - 1];
            shift -= 1;
        }
        rev_block.sources[insertion_point] = src.index;
        rev_block.mask = constants.denseMask(@intCast(live + 1));
    }

    // Self-edges must publish exactly once to avoid double-flip.
    if (src.index == dest.index) {
        src_node.publishStagingAdj();
    } else {
        dst_node.publishStagingAdj();
        src_node.publishStagingAdj();
    }

    if (old_block_fwd) |idx| try rcu.retireBlockFwd(core, idx);
    if (old_block_rev) |idx| try rcu.retireBlockRev(core, idx);

    _ = core.edge_count.fetchAdd(1, .monotonic);
    rcu.bumpEpoch(core);
    rcu.reclaimRetired(core);
}

/// Searches a contiguous or grouped adjacency chain for a single target value.
///
/// Returns the block index and slot where `target` was found, or null.
fn findSlotInAdj(
    core: *const graph.GraphCore,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    target: u32,
    side: adjacency.AdjSide,
) ?struct { block_idx: u32, slot: u7 } {
    if (block_count == 0) return null;

    if (group_count == 0) {
        const block_start = first_block;
        const block_end = block_start + block_count;
        for (block_start..block_end) |block_idx| {
            if (trySlotInBlock(core, @intCast(block_idx), target, side)) |slot| {
                return .{ .block_idx = @intCast(block_idx), .slot = slot };
            }
        }
        return null;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(core, group_idx);
        const group_start = group.start;
        const group_end = group_start + group.count;
        for (group_start..group_end) |block_idx| {
            if (trySlotInBlock(core, @intCast(block_idx), target, side)) |slot| {
                return .{ .block_idx = @intCast(block_idx), .slot = slot };
            }
        }
        group_idx = group.next;
    }
    return null;
}

/// Probes a single block for `target`, dispatching to the correct binary search.
fn trySlotInBlock(
    core: *const graph.GraphCore,
    block_idx: u32,
    target: u32,
    side: adjacency.AdjSide,
) ?u7 {
    return switch (side) {
        .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, page_ops.edgeBlockAtConst(core, block_idx, .fwd), target),
        .rev => adjacency.searchInBlock(types.EdgeBlockRev, page_ops.edgeBlockAtConst(core, block_idx, .rev), target),
    };
}

/// Rebuilds `staging_adj` by iterating over the published adjacency and
/// swapping `old_block` with `new_block` in the same position (COW copy,
/// block-by-block).  This handles any position (first, middle, or last) in
/// either contiguous or grouped chains correctly.
fn rebuildAdjWithReplace(
    core: *graph.GraphCore,
    staging_adj: *types.NodeAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    old_block: u32,
    new_block: u32,
    comptime side: adjacency.AdjSide,
) !void {
    // Zero only the comptime-selected side
    switch (side) {
        .fwd => {
            staging_adj.first_block_fwd = 0;
            staging_adj.block_count_fwd = 0;
            staging_adj.group_count_fwd = 0;
            staging_adj.first_group_fwd = 0;
        },
        .rev => {
            staging_adj.first_block_rev = 0;
            staging_adj.block_count_rev = 0;
            staging_adj.group_count_rev = 0;
            staging_adj.first_group_rev = 0;
        },
    }

    if (block_count == 0) return;

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            try appendBlockToStagingAdj(core, staging_adj, idx, side);
        }
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(core, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            try appendBlockToStagingAdj(core, staging_adj, idx, side);
        }
        group_idx = group.next;
    }
}

/// Appends one block to the staging adjacency, handling first-block vs grouped.
fn appendBlockToStagingAdj(
    core: *graph.GraphCore,
    adj: *types.NodeAdj,
    block_index: u32,
    comptime side: adjacency.AdjSide,
) !void {
    if (side == .fwd) {
        if (adj.block_count_fwd == 0) {
            adj.first_block_fwd = block_index;
            adj.block_count_fwd = 1;
        } else {
            try adjacency.appendGroupToAdj(core, adj, block_index, .fwd);
            adj.block_count_fwd += 1;
        }
    } else {
        if (adj.block_count_rev == 0) {
            adj.first_block_rev = block_index;
            adj.block_count_rev = 1;
        } else {
            try adjacency.appendGroupToAdj(core, adj, block_index, .rev);
            adj.block_count_rev += 1;
        }
    }
}

/// Removes the directed edge `src → dest` if it exists, returning `true`.
/// Returns `false` if the edge was not found (no mutation performed).
///
/// Fails with:
///   - `InvalidNode` if either endpoint does not exist.
///   - `CorruptGraph` if forward and reverse adjacency disagree (internal invariant).
///   - `RepairRequired` if a non-tail block would drop below `MIN_OCCUPANCY`.
///
/// Follows the RCU + COW mutation model (see module doc).  Works for any
/// block position (first, middle, or last) in both contiguous and grouped
/// adjacency chains.
pub fn removeEdge(core: *graph.GraphCore, src: types.NodeId, dest: types.NodeId) !bool {
    if (src.index >= core.node_count or dest.index >= core.node_count) return error.InvalidNode;

    const src_adj = page_ops.nodeAtConst(core, src).publishedAdj();
    const dest_adj = page_ops.nodeAtConst(core, dest).publishedAdj();

    const fwd_found = findSlotInAdj(
        core,
        src_adj.first_block_fwd,
        src_adj.block_count_fwd,
        src_adj.group_count_fwd,
        src_adj.first_group_fwd,
        dest.index,
        .fwd,
    ) orelse return false;

    const rev_found = findSlotInAdj(
        core,
        dest_adj.first_block_rev,
        dest_adj.block_count_rev,
        dest_adj.group_count_rev,
        dest_adj.first_group_rev,
        src.index,
        .rev,
    ) orelse return error.CorruptGraph;

    const fwd_live_before = @popCount(page_ops.edgeBlockAtConst(core, fwd_found.block_idx, .fwd).mask);
    const fwd_new_live = fwd_live_before - 1;
    const fwd_is_tail = fwd_found.block_idx == adjacency.tailBlockIndex(core, &src_adj, .fwd);
    if (!fwd_is_tail and fwd_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    const rev_live_before = @popCount(page_ops.edgeBlockAtConst(core, rev_found.block_idx, .rev).mask);
    const rev_new_live = rev_live_before - 1;
    const rev_is_tail = rev_found.block_idx == adjacency.tailBlockIndex(core, &dest_adj, .rev);
    if (!rev_is_tail and rev_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    var src_node = page_ops.nodeAt(core, src);
    src_node.copyPublishedToStaging();
    const src_staging_adj = src_node.stagingAdj();

    var dst_node = page_ops.nodeAt(core, dest);
    dst_node.copyPublishedToStaging();
    const dst_staging_adj = dst_node.stagingAdj();

    {
        const old_block = fwd_found.block_idx;
        const new_block = try page_ops.allocBlock(core, .fwd);
        page_ops.edgeBlockAt(core, new_block, .fwd).* = page_ops.edgeBlockAtConst(core, old_block, .fwd).*;

        const fwd_block = page_ops.edgeBlockAt(core, new_block, .fwd);
        const live = @popCount(fwd_block.mask);
        var shift: u7 = fwd_found.slot;
        while (shift < live - 1) : (shift += 1) {
            fwd_block.edges[shift] = fwd_block.edges[shift + 1];
        }
        const new_live = live - 1;
        fwd_block.mask = constants.denseMask(@intCast(new_live));

        // RFC §3.6: non-tail block must not drop below MIN_OCCUPANCY
        const is_tail_block = old_block == adjacency.tailBlockIndex(core, &src_adj, .fwd);
        if (!is_tail_block and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try rebuildAdjWithReplace(
            core,
            src_staging_adj,
            src_adj.first_block_fwd,
            src_adj.block_count_fwd,
            src_adj.group_count_fwd,
            src_adj.first_group_fwd,
            old_block,
            new_block,
            .fwd,
        );
        try rcu.retireBlockFwd(core, old_block);
    }

    {
        const old_block = rev_found.block_idx;
        const new_block = try page_ops.allocBlock(core, .rev);
        page_ops.edgeBlockAt(core, new_block, .rev).* = page_ops.edgeBlockAtConst(core, old_block, .rev).*;

        const rev_block = page_ops.edgeBlockAt(core, new_block, .rev);
        const live = @popCount(rev_block.mask);
        var shift: u7 = rev_found.slot;
        while (shift < live - 1) : (shift += 1) {
            rev_block.sources[shift] = rev_block.sources[shift + 1];
        }
        const new_live = live - 1;
        rev_block.mask = constants.denseMask(@intCast(new_live));

        // RFC §3.6: non-tail block must not drop below MIN_OCCUPANCY
        const is_tail_block = old_block == adjacency.tailBlockIndex(core, &dest_adj, .rev);
        if (!is_tail_block and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try rebuildAdjWithReplace(
            core,
            dst_staging_adj,
            dest_adj.first_block_rev,
            dest_adj.block_count_rev,
            dest_adj.group_count_rev,
            dest_adj.first_group_rev,
            old_block,
            new_block,
            .rev,
        );
        try rcu.retireBlockRev(core, old_block);
    }

    repair.updateRepairDebt(core, src_staging_adj, src.index, .fwd);
    repair.updateRepairDebt(core, dst_staging_adj, dest.index, .rev);

    if (src.index == dest.index) {
        src_node.publishStagingAdj();
    } else {
        dst_node.publishStagingAdj();
        src_node.publishStagingAdj();
    }

    _ = core.edge_count.fetchSub(1, .monotonic);
    rcu.bumpEpoch(core);
    rcu.reclaimRetired(core);

    return true;
}
