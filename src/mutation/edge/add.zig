const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_published_mod = @import("../../storage/node/published.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("../common.zig");
const add_build = @import("add/build.zig");
const add_finalize = @import("add/finalize.zig");
const shared = @import("shared.zig");
const side_runs = @import("../../adjacency/runs.zig");
const local_repair = @import("../local_repair.zig");

fn prepareAppendBlockSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !shared.PreparedAppendBlock {
    if (side_adj.block_count == 0) {
        return .{ .new_block = try scratch.allocBlock(graph, side) };
    }

    const tail_idx = (try adjacency.tailBlockIndexSideChecked(graph, side_adj)).?;
    const new_block = try scratch.allocBlock(graph, side);

    switch (side) {
        .fwd => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_idx, .fwd);
            if (page_ops.blockAliveCount(graph, tail_idx, .fwd) == constants.EDGES_PER_BLOCK) {
                return .{ .new_block = new_block, .tail_idx = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = tail_block.*;
            page_ops.setBlockAliveCount(graph, new_block, .fwd, page_ops.blockAliveCount(graph, tail_idx, .fwd));
            if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block).* = page_ops.edgeBlockFwdIdsAtConst(graph, tail_idx).*;
            if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, new_block).* = page_ops.edgeBlockFwdPropsAtConst(graph, tail_idx).*;
        },
        .rev => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_idx, .rev);
            if (page_ops.blockAliveCount(graph, tail_idx, .rev) == constants.EDGES_PER_BLOCK) {
                return .{ .new_block = new_block, .tail_idx = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .rev).* = tail_block.*;
            page_ops.setBlockAliveCount(graph, new_block, .rev, page_ops.blockAliveCount(graph, tail_idx, .rev));
        },
    }

    return .{ .old_block = tail_idx, .new_block = new_block, .tail_idx = tail_idx };
}

fn applyPreparedAppendSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !shared.AppliedAppend {
    if (side_adj.block_count == 0) {
        side_adj.first_block = prepared.new_block;
        side_adj.block_count = 1;
        side_adj.group_count = 0;
        side_adj.first_group = 0;
        return .{ .block_idx = prepared.new_block };
    }

    if (side_adj.block_count >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;

    if (prepared.old_block == null) {
        return try local_repair.appendPreparedBlock(graph, side_adj, prepared, side, scratch) orelse error.RepairRequired;
    }
    return try local_repair.replaceTailBlock(graph, side_adj, prepared, side, scratch) orelse error.RepairRequired;
}

const AddedEdge = struct { edge_id: types.EdgeId, prop_row: u32 };

/// Block preceding `block_idx` in the side layout, or null when `block_idx`
/// is the first block.
fn previousBlockInSide(graph: *const graph_core.GraphCore, side_view: types.SideAdj, block_idx: u32) ?u32 {
    const total_runs = side_runs.runCount(side_view);
    var prev_run_last: ?u32 = null;
    var run_idx: u16 = 0;
    while (run_idx < total_runs) : (run_idx += 1) {
        const run = side_runs.runAt(graph, side_view, run_idx) orelse return null;
        if (block_idx >= run.start and block_idx < run.start + run.count) {
            if (block_idx > run.start) return block_idx - 1;
            return prev_run_last;
        }
        prev_run_last = run.start + run.count - 1;
    }
    return null;
}

/// Whether inserting `key` into `insertion_block` (always the layout's tail)
/// keeps the side globally sorted. The hot path can preserve the published
/// `sorted` bit — instead of conservatively clearing it — exactly when the
/// side was already sorted and the new key is >= the last key of the block
/// preceding the insertion block: blocks before the tail are unchanged, the
/// in-block insert keeps per-block order, so the cross-block boundary is the
/// only thing to re-check. Append-mostly workloads (ascending ids) therefore
/// keep conclusive binary-search misses for duplicate checks and removals.
fn appendKeepsGloballySorted(
    graph: *const graph_core.GraphCore,
    side_view: types.SideAdj,
    insertion_block: u32,
    key: u32,
    sorted_before: bool,
    comptime side: adjacency.AdjSide,
) bool {
    if (!sorted_before) return false;
    const prev_block = previousBlockInSide(graph, side_view, insertion_block) orelse return true;
    const alive = page_ops.blockAliveCount(graph, prev_block, side);
    if (alive == 0) return false;
    const last_key = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, prev_block, .fwd).destinations[alive - 1],
        .rev => page_ops.edgeBlockAtConst(graph, prev_block, .rev).sources[alive - 1],
    };
    return key >= last_key;
}

fn addEdgeImpl(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
    relation: u16,
    flags: u16,
) !AddedEdge {
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    const source_pub = node_access.publishedFwdFromMeta(graph, source, endpoints.source_meta);
    const destination_pub = node_access.publishedRevFromMeta(graph, destination, endpoints.destination_meta);
    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    node_access.copyPublishedToStagingFwd(graph, source, endpoints.source_meta);
    node_access.copyPublishedToStagingRev(graph, destination, endpoints.destination_meta);
    const source_staging = node_access.stagingFwd(graph, source, endpoints.source_meta);
    const destination_staging = node_access.stagingRev(graph, destination, endpoints.destination_meta);

    if (!graph.multigraph_enabled) {
        const source_sorted = endpoints.source_published.publishedFwdSortedFromMeta(endpoints.source_meta);
        if (try adjacency.hasEdgeInSideAdjChecked(graph, source_pub, destination.index, source_sorted)) {
            return error.EdgeAlreadyExists;
        }
    }

    if (node_access.publishedFwdDegreeFromMetaAtConst(graph, source, endpoints.source_meta) >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;
    if (node_access.publishedRevDegreeFromMetaAtConst(graph, destination, endpoints.destination_meta) >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const edge_id = if (graph.multigraph_enabled) try endpoints.claims.source_hot.nextEdgeId() else types.EdgeId{ .local = 0 };
    const prop_row: u32 = if (graph.edge_properties_enabled) try scratch.allocPropRow(graph) else 0;

    const old_forward_groups = shared.OldGroupChain.captureSide(&source_pub);
    const old_reverse_groups = shared.OldGroupChain.captureSide(&destination_pub);

    var forward_prepared: shared.PreparedAppendBlock = .{ .new_block = 0 };
    var reverse_prepared: shared.PreparedAppendBlock = .{ .new_block = 0 };
    var forward_applied: shared.AppliedAppend = .{ .block_idx = 0 };
    var reverse_applied: shared.AppliedAppend = .{ .block_idx = 0 };
    var fwd_sorted_after = false;
    var rev_sorted_after = false;

    if (add_build.canUseTinyFwdSide(graph, source_pub)) {
        source_staging.* = try add_build.buildForwardTinyOrPromoted(graph, source_pub, destination, relation, flags, edge_id.local, prop_row, &scratch);
        // Tiny slots and single promoted blocks are trivially globally sorted.
        fwd_sorted_after = true;
    } else {
        const fwd_sorted_before = endpoints.source_published.publishedFwdSortedFromMeta(endpoints.source_meta);
        forward_prepared = try prepareAppendBlockSide(graph, source_staging, .fwd, &scratch);
        try local_repair.ensureTailCowGroupConstraint(graph, source_staging, forward_prepared);
        forward_applied = try applyPreparedAppendSideTracked(graph, source_staging, forward_prepared, .fwd, &scratch);
        fwd_sorted_after = appendKeepsGloballySorted(graph, source_staging.*, forward_applied.block_idx, destination.index, fwd_sorted_before, .fwd);
        try add_build.insertForwardEdge(graph, forward_applied.block_idx, destination, relation, flags, edge_id.local, prop_row);
    }

    if (add_build.canUseTinyRevSide(destination_pub)) {
        destination_staging.* = try add_build.buildReverseTinyOrPromoted(graph, destination_pub, source, &scratch);
        rev_sorted_after = true;
    } else {
        const rev_sorted_before = endpoints.destination_published.publishedRevSortedFromMeta(endpoints.destination_meta);
        reverse_prepared = try prepareAppendBlockSide(graph, destination_staging, .rev, &scratch);
        try local_repair.ensureTailCowGroupConstraint(graph, destination_staging, reverse_prepared);
        reverse_applied = try applyPreparedAppendSideTracked(graph, destination_staging, reverse_prepared, .rev, &scratch);
        rev_sorted_after = appendKeepsGloballySorted(graph, destination_staging.*, reverse_applied.block_idx, source.index, rev_sorted_before, .rev);
        add_build.insertReverseEdge(graph, reverse_applied.block_idx, source);
    }

    const publish_adj = add_finalize.updateAddedDebt(
        graph,
        &endpoints,
        source,
        destination,
        source_staging.*,
        destination_staging.*,
    );

    try add_finalize.finalizeAdded(
        graph,
        &scratch,
        &endpoints,
        source,
        destination,
        publish_adj,
        forward_prepared,
        forward_applied,
        reverse_prepared,
        reverse_applied,
        old_forward_groups,
        old_reverse_groups,
        fwd_sorted_after,
        rev_sorted_after,
    );
    // Tiny sides COW into a fresh slot on every mutation; once the new side is
    // published the superseded slot must enter the retired stack or it leaks.
    if (node_published_mod.NodePublished.isTiny(&source_pub)) {
        rcu.retireTinyBlock(graph, source_pub.first_block, .fwd);
    }
    if (node_published_mod.NodePublished.isTiny(&destination_pub)) {
        rcu.retireTinyBlock(graph, destination_pub.first_block, .rev);
    }
    rcu.bumpEpoch(graph);
    writer_guard.end();

    return .{ .edge_id = edge_id, .prop_row = prop_row };
}

/// Adds one edge between two live nodes, rejecting duplicates in simple-graph mode.
pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    _ = try addEdgeImpl(graph, source, destination, relation, flags);
}

/// Adds one edge and returns its source-local edge id.
/// Requires multigraph mode.
pub fn addEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !types.EdgeId {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    return (try addEdgeImpl(graph, source, destination, relation, flags)).edge_id;
}

/// Adds one edge and returns its stable property row id.
/// Requires edge_properties mode.
pub fn addEdgeWithProperties(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !u32 {
    if (!graph.edge_properties_enabled) return error.UnsupportedOperation;
    return (try addEdgeImpl(graph, source, destination, relation, flags)).prop_row;
}
