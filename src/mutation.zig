//! Edge insertion and removal — the mutable graph of the graph engine.
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

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");
const repair = @import("repair.zig");
const query = @import("query.zig");

/// Tracks which adjacency claims were successfully acquired during a mutation,
/// so the deferred release only drops the ones that were actually taken.
const ClaimedAdjacencies = struct {
    source_node: *types.NodeBuffer,
    destination_node: *types.NodeBuffer,
    source_fwd_claimed: bool = false,
    destination_rev_claimed: bool = false,

    fn release(self: *ClaimedAdjacencies) void {
        if (self.destination_rev_claimed) self.destination_node.rev_claim.store(0, .release);
        if (self.source_fwd_claimed) self.source_node.fwd_claim.store(0, .release);
    }
};

const WriterGuard = struct {
    graph: *graph_core.GraphCore,
    active: bool = true,

    fn end(self: *WriterGuard) void {
        if (!self.active) return;
        _ = self.graph.active_writers.fetchSub(1, .acq_rel);
        self.active = false;
    }
};

fn beginWriter(graph: *graph_core.GraphCore) WriterGuard {
    const previous_writers = graph.active_writers.fetchAdd(1, .acq_rel);
    if (previous_writers > 0) graph.debug_retired_enabled.store(false, .release);
    return .{ .graph = graph };
}

fn tryClaimAdjacencies(source_node: *types.NodeBuffer, destination_node: *types.NodeBuffer) !ClaimedAdjacencies {
    var claims = ClaimedAdjacencies{
        .source_node = source_node,
        .destination_node = destination_node,
    };

    if (source_node.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
    claims.source_fwd_claimed = true;
    errdefer claims.release();

    if (destination_node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
    claims.destination_rev_claimed = true;

    return claims;
}

/// Adds a directed edge `src → dest` with a relation label and flags.
///
/// Fails with:
///   - `InvalidNode` if either endpoint does not exist.
///   - `EdgeAlreadyExists` if the edge is already present (non-multigraph mode).
///
/// Follows the RCU + COW mutation model (see module doc).
pub fn addEdge(graph: *graph_core.GraphCore, src: types.NodeId, dest: types.NodeId, relation: u16, flags: u16) !void {
    if (src.index >= graph.node_count or dest.index >= graph.node_count) return error.InvalidNode;

    var src_node = page_ops.nodeAt(graph, src);
    var dst_node = page_ops.nodeAt(graph, dest);

    var claims = try tryClaimAdjacencies(src_node, dst_node);
    defer claims.release();

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    const src_published_adj_index: u1 = src_node.loadPublishedAdjIndex();
    const src_staging_adj_index: u1 = 1 - src_published_adj_index;
    src_node.copyPublishedToStaging();
    const src_adj = &src_node.adj_buffers[src_staging_adj_index];

    const dst_published_adj_index: u1 = dst_node.loadPublishedAdjIndex();
    const dst_staging_adj_index: u1 = 1 - dst_published_adj_index;
    dst_node.copyPublishedToStaging();
    const dst_adj = &dst_node.adj_buffers[dst_staging_adj_index];

    if (adjacency.hasEdgeInAdj(graph, src_node.adj_buffers[src_published_adj_index], dest.index)) {
        return error.EdgeAlreadyExists;
    }

    // ── Pre-allocate forward block before any staging mutation ──
    var old_block_fwd: ?u32 = null;
    var block_fwd_idx: u32 = undefined;
    var fwd_tail_idx: u32 = undefined;

    if (src_adj.block_count_fwd == 0) {
        block_fwd_idx = try page_ops.allocBlock(graph, .fwd);
    } else {
        fwd_tail_idx = adjacency.tailBlockIndex(graph, src_adj, .fwd);
        const tail_block = page_ops.edgeBlockAt(graph, fwd_tail_idx, .fwd);
        if (@popCount(tail_block.mask) == 64) {
            block_fwd_idx = try page_ops.allocBlock(graph, .fwd);
        } else {
            old_block_fwd = fwd_tail_idx;
            block_fwd_idx = try page_ops.allocBlock(graph, .fwd);
            page_ops.edgeBlockAt(graph, block_fwd_idx, .fwd).* = tail_block.*;
        }
    }

    // ── Pre-allocate reverse block before any staging mutation ──
    var old_block_rev: ?u32 = null;
    var block_rev_idx: u32 = undefined;
    var rev_tail_idx: u32 = undefined;

    if (dst_adj.block_count_rev == 0) {
        block_rev_idx = try page_ops.allocBlock(graph, .rev);
    } else {
        rev_tail_idx = adjacency.tailBlockIndex(graph, dst_adj, .rev);
        const tail_block = page_ops.edgeBlockAt(graph, rev_tail_idx, .rev);
        if (@popCount(tail_block.mask) == 64) {
            block_rev_idx = try page_ops.allocBlock(graph, .rev);
        } else {
            old_block_rev = rev_tail_idx;
            block_rev_idx = try page_ops.allocBlock(graph, .rev);
            page_ops.edgeBlockAt(graph, block_rev_idx, .rev).* = tail_block.*;
        }
    }

    // ── Check COW group constraints before mutating staging ──
    if (old_block_fwd != null and src_adj.block_count_fwd > 1) {
        if (src_adj.group_count_fwd >= constants.MAX_GROUPS_PER_NODE) {
            const first_group = src_adj.first_group_fwd;
            var gidx = first_group;
            while (gidx != constants.END_OF_CHAIN) {
                const group = page_ops.groupAtConst(graph, gidx);
                if (fwd_tail_idx >= group.start and fwd_tail_idx < group.start + group.count) {
                    if (group.count > 1) return error.RepairRequired;
                    break;
                }
                gidx = group.next;
            }
        }
    }
    if (old_block_rev != null and dst_adj.block_count_rev > 1) {
        if (dst_adj.group_count_rev >= constants.MAX_GROUPS_PER_NODE) {
            const first_group = dst_adj.first_group_rev;
            var gidx = first_group;
            while (gidx != constants.END_OF_CHAIN) {
                const group = page_ops.groupAtConst(graph, gidx);
                if (rev_tail_idx >= group.start and rev_tail_idx < group.start + group.count) {
                    if (group.count > 1) return error.RepairRequired;
                    break;
                }
                gidx = group.next;
            }
        }
    }

    // ── Mutate forward staging ──
    if (src_adj.block_count_fwd == 0) {
        src_adj.first_block_fwd = block_fwd_idx;
        src_adj.block_count_fwd = 1;
    } else if (old_block_fwd) |_| {
        if (src_adj.block_count_fwd == 1) {
            src_adj.first_block_fwd = block_fwd_idx;
        } else {
            const was_contiguous = src_adj.group_count_fwd == 0;
            adjacency.removeTailFromAdj(graph, src_adj, .fwd);
            try adjacency.appendGroupToAdj(graph, src_adj, block_fwd_idx, .fwd);
            if (was_contiguous) src_adj.block_count_fwd += 1;
        }
    } else {
        if (block_fwd_idx == fwd_tail_idx + 1) {
            if (src_adj.group_count_fwd > 0) {
                adjacency.extendTailGroup(graph, src_adj, .fwd);
            }
            src_adj.block_count_fwd += 1;
        } else {
            try adjacency.appendGroupToAdj(graph, src_adj, block_fwd_idx, .fwd);
            src_adj.block_count_fwd += 1;
        }
    }

    // ── Insert forward edge ──
    {
        const fwd_block = page_ops.edgeBlockAt(graph, block_fwd_idx, .fwd);
        const live = @popCount(fwd_block.mask);
        var insertion_point: u7 = 0;
        var search_end: u7 = @intCast(live);
        while (insertion_point < search_end) {
            const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
            if (fwd_block.edges[probe].destination < dest.index) {
                insertion_point = probe + 1;
            } else if (fwd_block.edges[probe].destination == dest.index) {
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
        fwd_block.edges[insertion_point] = types.Edge{ .destination = dest.index, .relation = relation, .flags = @bitCast(flags) };
        fwd_block.mask = constants.denseMask(@intCast(live + 1));
    }

    // ── Mutate reverse staging ──
    if (dst_adj.block_count_rev == 0) {
        dst_adj.first_block_rev = block_rev_idx;
        dst_adj.block_count_rev = 1;
    } else if (old_block_rev) |_| {
        if (dst_adj.block_count_rev == 1) {
            dst_adj.first_block_rev = block_rev_idx;
        } else {
            const was_contiguous = dst_adj.group_count_rev == 0;
            adjacency.removeTailFromAdj(graph, dst_adj, .rev);
            try adjacency.appendGroupToAdj(graph, dst_adj, block_rev_idx, .rev);
            if (was_contiguous) dst_adj.block_count_rev += 1;
        }
    } else {
        if (block_rev_idx == rev_tail_idx + 1) {
            if (dst_adj.group_count_rev > 0) {
                adjacency.extendTailGroup(graph, dst_adj, .rev);
            }
            dst_adj.block_count_rev += 1;
        } else {
            try adjacency.appendGroupToAdj(graph, dst_adj, block_rev_idx, .rev);
            dst_adj.block_count_rev += 1;
        }
    }

    // ── Insert reverse edge ──
    {
        const rev_block = page_ops.edgeBlockAt(graph, block_rev_idx, .rev);
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

    if (old_block_fwd) |idx| try rcu.retireBlockFwd(graph, idx);
    if (old_block_rev) |idx| try rcu.retireBlockRev(graph, idx);

    _ = graph.edge_count.fetchAdd(1, .monotonic);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);
}

/// Searches a contiguous or grouped adjacency chain for a single target value.
///
/// Returns the block index and slot where `target` was found, or null.
fn findSlotInAdj(
    graph: *const graph_core.GraphCore,
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
            if (trySlotInBlock(graph, @intCast(block_idx), target, side)) |slot| {
                return .{ .block_idx = @intCast(block_idx), .slot = slot };
            }
        }
        return null;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        const group_start = group.start;
        const group_end = group_start + group.count;
        for (group_start..group_end) |block_idx| {
            if (trySlotInBlock(graph, @intCast(block_idx), target, side)) |slot| {
                return .{ .block_idx = @intCast(block_idx), .slot = slot };
            }
        }
        group_idx = group.next;
    }
    return null;
}

/// Probes a single block for `target`, dispatching to the correct binary search.
fn trySlotInBlock(
    graph: *const graph_core.GraphCore,
    block_idx: u32,
    target: u32,
    side: adjacency.AdjSide,
) ?u7 {
    return switch (side) {
        .fwd => adjacency.searchInBlock(types.EdgeBlockFwd, page_ops.edgeBlockAtConst(graph, block_idx, .fwd), target),
        .rev => adjacency.searchInBlock(types.EdgeBlockRev, page_ops.edgeBlockAtConst(graph, block_idx, .rev), target),
    };
}

/// Rebuilds `staging_adj` by walking the published adjacency and replacing
/// `old_block` with `new_block`.  Detects contiguous runs to minimise group
/// allocations and chain links — O(N) instead of O(N²).
fn rebuildAdjWithReplace(
    graph: *graph_core.GraphCore,
    staging_adj: *types.NodeAdj,
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
    old_block: u32,
    new_block: u32,
    comptime side: adjacency.AdjSide,
) !void {
    // Zero the comptime-selected side
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

    var run_start: u32 = 0;
    var run_count: u16 = 0;
    var total_blocks: u16 = 0;
    var first_block_set: bool = false;
    var tail_group: ?u32 = null;

    const EmitCtx = struct {
        fn flush(
            adj: *types.NodeAdj,
            graph_ptr: *graph_core.GraphCore,
            comptime dir: adjacency.AdjSide,
            run_start_ptr: *u32,
            run_count_ptr: *u16,
            total_blocks_ptr: *u16,
            first_block_set_ptr: *bool,
            tail_group_ptr: *?u32,
        ) !void {
            if (run_count_ptr.* == 0) return;
            if (!first_block_set_ptr.*) {
                switch (dir) {
                    .fwd => {
                        adj.first_block_fwd = run_start_ptr.*;
                        adj.block_count_fwd = run_count_ptr.*;
                    },
                    .rev => {
                        adj.first_block_rev = run_start_ptr.*;
                        adj.block_count_rev = run_count_ptr.*;
                    },
                }
                first_block_set_ptr.* = true;
            } else if (tail_group_ptr.* == null and (switch (dir) {
                .fwd => adj.group_count_fwd,
                .rev => adj.group_count_rev,
            }) == 0) {
                const prefix_group = try page_ops.allocGroup(graph_ptr);
                const group = try page_ops.allocGroup(graph_ptr);
                const first_start: u32 = switch (dir) {
                    .fwd => adj.first_block_fwd,
                    .rev => adj.first_block_rev,
                };
                const first_cnt: u16 = switch (dir) {
                    .fwd => adj.block_count_fwd,
                    .rev => adj.block_count_rev,
                };
                page_ops.groupAt(graph_ptr, prefix_group).* = .{ .start = first_start, .count = first_cnt, .next = group };
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                switch (dir) {
                    .fwd => {
                        adj.first_group_fwd = prefix_group;
                        adj.group_count_fwd = 2;
                    },
                    .rev => {
                        adj.first_group_rev = prefix_group;
                        adj.group_count_rev = 2;
                    },
                }
                tail_group_ptr.* = group;
            } else {
                const group = try page_ops.allocGroup(graph_ptr);
                page_ops.groupAt(graph_ptr, group).* = .{ .start = run_start_ptr.*, .count = run_count_ptr.*, .next = constants.END_OF_CHAIN };
                page_ops.groupAt(graph_ptr, tail_group_ptr.*.?).next = group;
                tail_group_ptr.* = group;
                switch (dir) {
                    .fwd => adj.group_count_fwd += 1,
                    .rev => adj.group_count_rev += 1,
                }
            }
            total_blocks_ptr.* += run_count_ptr.*;
        }
    };

    if (group_count == 0) {
        for (first_block..first_block + block_count) |block_idx| {
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                run_start = idx;
                run_count = 1;
            }
        }
        try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
        switch (side) {
            .fwd => staging_adj.block_count_fwd = total_blocks,
            .rev => staging_adj.block_count_rev = total_blocks,
        }
        return;
    }

    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_idx| {
            const idx: u32 = if (block_idx == old_block) new_block else @intCast(block_idx);
            if (run_count > 0 and idx == run_start + run_count) {
                run_count += 1;
            } else {
                try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
                run_start = idx;
                run_count = 1;
            }
        }
        group_idx = group.next;
    }
    try EmitCtx.flush(staging_adj, graph, side, &run_start, &run_count, &total_blocks, &first_block_set, &tail_group);
    switch (side) {
        .fwd => staging_adj.block_count_fwd = total_blocks,
        .rev => staging_adj.block_count_rev = total_blocks,
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
pub fn removeEdge(graph: *graph_core.GraphCore, src: types.NodeId, dest: types.NodeId) !bool {
    if (src.index >= graph.node_count or dest.index >= graph.node_count) return error.InvalidNode;

    var src_node = page_ops.nodeAt(graph, src);
    var dst_node = page_ops.nodeAt(graph, dest);

    var claims = try tryClaimAdjacencies(src_node, dst_node);
    defer claims.release();

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    const src_adj = src_node.publishedAdj();
    const dest_adj = dst_node.publishedAdj();

    const fwd_found = findSlotInAdj(
        graph,
        src_adj.first_block_fwd,
        src_adj.block_count_fwd,
        src_adj.group_count_fwd,
        src_adj.first_group_fwd,
        dest.index,
        .fwd,
    ) orelse return false;

    const rev_found = findSlotInAdj(
        graph,
        dest_adj.first_block_rev,
        dest_adj.block_count_rev,
        dest_adj.group_count_rev,
        dest_adj.first_group_rev,
        src.index,
        .rev,
    ) orelse return error.CorruptGraph;

    const fwd_live_before = @popCount(page_ops.edgeBlockAtConst(graph, fwd_found.block_idx, .fwd).mask);
    const fwd_new_live = fwd_live_before - 1;
    const fwd_tail = adjacency.tailBlockIndex(graph, &src_adj, .fwd);
    const fwd_is_tail = fwd_found.block_idx == fwd_tail;
    if (!fwd_is_tail and fwd_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    const rev_live_before = @popCount(page_ops.edgeBlockAtConst(graph, rev_found.block_idx, .rev).mask);
    const rev_new_live = rev_live_before - 1;
    const rev_tail = adjacency.tailBlockIndex(graph, &dest_adj, .rev);
    const rev_is_tail = rev_found.block_idx == rev_tail;
    if (!rev_is_tail and rev_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    src_node.copyPublishedToStaging();
    const src_staging_adj = src_node.stagingAdj();

    dst_node.copyPublishedToStaging();
    const dst_staging_adj = dst_node.stagingAdj();

    {
        const old_block = fwd_found.block_idx;
        const new_block = try page_ops.allocBlock(graph, .fwd);
        page_ops.edgeBlockAt(graph, new_block, .fwd).* = page_ops.edgeBlockAtConst(graph, old_block, .fwd).*;

        const fwd_block = page_ops.edgeBlockAt(graph, new_block, .fwd);
        const live = @popCount(fwd_block.mask);
        var shift: u7 = fwd_found.slot;
        while (shift < live - 1) : (shift += 1) {
            fwd_block.edges[shift] = fwd_block.edges[shift + 1];
        }
        const new_live = live - 1;
        fwd_block.mask = constants.denseMask(@intCast(new_live));

        // RFC §3.6: non-tail block must not drop below MIN_OCCUPANCY
        if (!fwd_is_tail and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try rebuildAdjWithReplace(
            graph,
            src_staging_adj,
            src_adj.first_block_fwd,
            src_adj.block_count_fwd,
            src_adj.group_count_fwd,
            src_adj.first_group_fwd,
            old_block,
            new_block,
            .fwd,
        );
        try rcu.retireBlockFwd(graph, old_block);
    }

    {
        const old_block = rev_found.block_idx;
        const new_block = try page_ops.allocBlock(graph, .rev);
        page_ops.edgeBlockAt(graph, new_block, .rev).* = page_ops.edgeBlockAtConst(graph, old_block, .rev).*;

        const rev_block = page_ops.edgeBlockAt(graph, new_block, .rev);
        const live = @popCount(rev_block.mask);
        var shift: u7 = rev_found.slot;
        while (shift < live - 1) : (shift += 1) {
            rev_block.sources[shift] = rev_block.sources[shift + 1];
        }
        const new_live = live - 1;
        rev_block.mask = constants.denseMask(@intCast(new_live));

        // RFC §3.6: non-tail block must not drop below MIN_OCCUPANCY
        if (!rev_is_tail and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try rebuildAdjWithReplace(
            graph,
            dst_staging_adj,
            dest_adj.first_block_rev,
            dest_adj.block_count_rev,
            dest_adj.group_count_rev,
            dest_adj.first_group_rev,
            old_block,
            new_block,
            .rev,
        );
        try rcu.retireBlockRev(graph, old_block);
    }

    repair.updateRepairDebt(graph, src_staging_adj, src.index, .fwd);
    repair.updateRepairDebt(graph, dst_staging_adj, dest.index, .rev);

    if (src.index == dest.index) {
        src_node.publishStagingAdj();
    } else {
        dst_node.publishStagingAdj();
        src_node.publishStagingAdj();
    }

    _ = graph.edge_count.fetchSub(1, .monotonic);
    rcu.bumpEpoch(graph);
    writer_guard.end();
    rcu.reclaimRetired(graph);

    return true;
}

/// Marks `node` as removed and clears all its outgoing edges.
/// Incoming edges to `node` from other nodes persist as tombstoned
/// references until compacted by `repairBudgeted` or during future
/// mutations on those nodes.
pub fn removeNode(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (node.index >= graph.node_count) return error.InvalidNode;

    // Collect every outgoing edge from the published forward adjacency.
    const FwdSlot = struct { dest: u32, block_idx: u32, slot: u7 };
    var fwd_slots: std.ArrayList(FwdSlot) = .empty;
    defer fwd_slots.deinit(graph.allocator);

    {
        const pub_adj = page_ops.nodeAtConst(graph, node).publishedAdj();
        if (pub_adj.block_count_fwd > 0) {
            if (pub_adj.group_count_fwd == 0) {
                const start = pub_adj.first_block_fwd;
                const end = start + pub_adj.block_count_fwd;
                for (start..end) |block_idx| {
                    const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
                    const live = @popCount(block.mask);
                    for (0..live) |slot| {
                        try fwd_slots.append(graph.allocator, .{
                            .dest = block.edges[slot].destination,
                            .block_idx = @intCast(block_idx),
                            .slot = @intCast(slot),
                        });
                    }
                }
            } else {
                var group_idx = pub_adj.first_group_fwd;
                while (group_idx != constants.END_OF_CHAIN) {
                    const group = page_ops.groupAtConst(graph, group_idx);
                    for (group.start..group.start + group.count) |block_idx| {
                        const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
                        const live = @popCount(block.mask);
                        for (0..live) |slot| {
                            try fwd_slots.append(graph.allocator, .{
                                .dest = block.edges[slot].destination,
                                .block_idx = @intCast(block_idx),
                                .slot = @intCast(slot),
                            });
                        }
                    }
                    group_idx = group.next;
                }
            }
        }
    }

    // Claim and clear the forward adjacency entirely, then mark removed.
    {
        const node_buf = page_ops.nodeAt(graph, node);
        if (node_buf.fwd_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
        defer node_buf.fwd_claim.store(0, .release);

        var writer_guard = beginWriter(graph);
        defer writer_guard.end();

        const pub_adj_before = node_buf.publishedAdj();

        // Retire all forward blocks.
        if (pub_adj_before.block_count_fwd > 0) {
            if (pub_adj_before.group_count_fwd == 0) {
                const start = pub_adj_before.first_block_fwd;
                const end = start + pub_adj_before.block_count_fwd;
                for (start..end) |block_idx| {
                    try rcu.retireBlockFwd(graph, @intCast(block_idx));
                }
            } else {
                var group_idx = pub_adj_before.first_group_fwd;
                while (group_idx != constants.END_OF_CHAIN) {
                    const group = page_ops.groupAtConst(graph, group_idx);
                    for (group.start..group.start + group.count) |block_idx| {
                        try rcu.retireBlockFwd(graph, @intCast(block_idx));
                    }
                    group_idx = group.next;
                }
            }
        }

        node_buf.copyPublishedToStaging();
        const staging = node_buf.stagingAdj();
        staging.first_block_fwd = 0;
        staging.block_count_fwd = 0;
        staging.group_count_fwd = 0;
        staging.first_group_fwd = 0;
        staging.flags.removed = true;
        node_buf.publishStagingAdj();
        writer_guard.end();
    }

    // Remove each reverse entry. The forward adjacency is already cleared,
    // so we handle only the reverse side per destination.
    for (fwd_slots.items) |fs| {
        try removeReverseSlot(graph, node.index, fs.dest);
    }

    rcu.bumpEpoch(graph);
    rcu.reclaimRetired(graph);
}

/// Removes the reverse-side slot for a single edge (src_idx → dest_idx).
/// Used by removeNode when the forward adjacency has already been cleared.
/// Handles claims, COW, publication, and edge_count decrement for the
/// destination's reverse adjacency only.
fn removeReverseSlot(
    graph: *graph_core.GraphCore,
    src_idx: u32,
    dest_idx: u32,
) !void {
    const dest_node = page_ops.nodeAt(graph, .{ .index = dest_idx });
    if (dest_node.rev_claim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.ConcurrentMutation;
    defer dest_node.rev_claim.store(0, .release);

    var writer_guard = beginWriter(graph);
    defer writer_guard.end();

    const dest_adj = dest_node.publishedAdj();

    const rev_found = findSlotInAdj(
        graph,
        dest_adj.first_block_rev,
        dest_adj.block_count_rev,
        dest_adj.group_count_rev,
        dest_adj.first_group_rev,
        src_idx,
        .rev,
    ) orelse return error.CorruptGraph;

    const rev_live_before = @popCount(page_ops.edgeBlockAtConst(graph, rev_found.block_idx, .rev).mask);
    const rev_new_live = rev_live_before - 1;
    const rev_tail = adjacency.tailBlockIndex(graph, &dest_adj, .rev);
    const rev_is_tail = rev_found.block_idx == rev_tail;
    if (!rev_is_tail and rev_new_live < constants.MIN_OCCUPANCY) return error.RepairRequired;

    dest_node.copyPublishedToStaging();
    const dst_staging_adj = dest_node.stagingAdj();

    {
        const old_block = rev_found.block_idx;
        const new_block = try page_ops.allocBlock(graph, .rev);
        page_ops.edgeBlockAt(graph, new_block, .rev).* = page_ops.edgeBlockAtConst(graph, old_block, .rev).*;

        const rev_block = page_ops.edgeBlockAt(graph, new_block, .rev);
        const live = @popCount(rev_block.mask);
        var shift: u7 = rev_found.slot;
        while (shift < live - 1) : (shift += 1) {
            rev_block.sources[shift] = rev_block.sources[shift + 1];
        }
        const new_live = live - 1;
        rev_block.mask = constants.denseMask(@intCast(new_live));

        if (!rev_is_tail and new_live < constants.MIN_OCCUPANCY) {
            return error.RepairRequired;
        }

        try rebuildAdjWithReplace(
            graph,
            dst_staging_adj,
            dest_adj.first_block_rev,
            dest_adj.block_count_rev,
            dest_adj.group_count_rev,
            dest_adj.first_group_rev,
            old_block,
            new_block,
            .rev,
        );
        try rcu.retireBlockRev(graph, old_block);
    }

    repair.updateRepairDebt(graph, dst_staging_adj, dest_idx, .rev);

    // Self-edges: forward adjacency was already published in the caller;
    // the reverse side here operates on the same node buffer, so publish.
    dest_node.publishStagingAdj();

    _ = graph.edge_count.fetchSub(1, .monotonic);
    writer_guard.end();
}
