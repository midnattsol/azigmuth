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
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .fwd).* = tail_block.*;
            if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, new_block).* = page_ops.edgeBlockFwdIdsAtConst(graph, tail_idx).*;
        },
        .rev => {
            const tail_block = page_ops.edgeBlockAt(graph, tail_idx, .rev);
            if (@popCount(tail_block.mask) == 64) {
                return .{ .new_block = new_block, .tail_index = tail_idx };
            }
            page_ops.edgeBlockAt(graph, new_block, .rev).* = tail_block.*;
        },
    }

    return .{ .old_block = tail_idx, .new_block = new_block, .tail_index = tail_idx };
}

fn ensureTailCowGroupConstraintSide(
    graph: *graph_core.GraphCore,
    side_adj: *const types.SideAdj,
    prepared: shared.PreparedAppendBlock,
) !void {
    try local_side_edit.ensureTailCowGroupConstraint(graph, side_adj, prepared);
}

fn applyPreparedAppendSideTracked(
    graph: *graph_core.GraphCore,
    side_adj: *types.SideAdj,
    prepared: shared.PreparedAppendBlock,
    comptime side: adjacency.AdjSide,
    scratch: *common.MutationScratch,
) !shared.AppliedAppend {
    if (@as(u22, side_adj.block_count) >= constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;
    return try local_side_edit.tryApplyPreparedAppendFast(graph, side_adj, prepared, side, scratch) orelse error.RepairRequired;
}

fn insertForwardEdge(graph: *graph_core.GraphCore, block_idx: u32, destination: types.NodeId, relation: u16, flags: u16, edge_id: u32) !void {
    const forward_block = page_ops.edgeBlockAt(graph, block_idx, .fwd);
    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, block_idx) else undefined;
    const live = @popCount(forward_block.mask);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(live);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (forward_block.edges[probe].destination < destination.index) {
            insertion_point = probe + 1;
        } else if (forward_block.edges[probe].destination == destination.index) {
            if (!graph.multigraph_enabled) return error.EdgeAlreadyExists;
            if (graph.multigraph_enabled and id_block.ids[probe] < edge_id) {
                insertion_point = probe + 1;
            } else {
                search_end = probe;
            }
        } else {
            search_end = probe;
        }
    }
    var shift: u7 = @intCast(live);
    while (shift > insertion_point) {
        forward_block.edges[shift] = forward_block.edges[shift - 1];
        if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift - 1];
        shift -= 1;
    }
    forward_block.edges[insertion_point] = types.Edge{ .destination = destination.index, .relation = relation, .flags = @bitCast(flags) };
    if (graph.multigraph_enabled) id_block.ids[insertion_point] = edge_id;
    forward_block.mask = constants.denseMask(@intCast(live + 1));
}

fn insertReverseEdge(graph: *graph_core.GraphCore, block_idx: u32, source: types.NodeId) void {
    const reverse_block = page_ops.edgeBlockAt(graph, block_idx, .rev);
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

fn addEdgeImpl(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    destination: types.NodeId,
    relation: u16,
    flags: u16,
) !types.EdgeId {
    var endpoints = try shared.claimEndpoints(graph, source, destination);
    defer endpoints.claims.release();

    const source_pub = endpoints.source_node.publishedFwdFromMeta(endpoints.source_meta);

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    endpoints.source_node.copyPublishedToStagingFwd(endpoints.source_meta);
    endpoints.destination_node.copyPublishedToStagingRev(endpoints.destination_meta);
    const source_staging = endpoints.source_node.stagingFwd(endpoints.source_meta);
    const destination_staging = endpoints.destination_node.stagingRev(endpoints.destination_meta);

    if (!graph.multigraph_enabled) {
        if (try adjacency.hasEdgeInSideAdjChecked(graph, source_pub, destination.index)) {
            return error.EdgeAlreadyExists;
        }
    }

    if (endpoints.source_meta.degree_fwd >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;
    if (endpoints.destination_meta.degree_rev >= constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    const edge_id = if (graph.multigraph_enabled) try endpoints.source_node.nextEdgeId() else types.EdgeId{ .local = 0 };

    const forward_prepared = try prepareAppendBlockSide(graph, source_staging, .fwd, &scratch);
    const reverse_prepared = try prepareAppendBlockSide(graph, destination_staging, .rev, &scratch);

    try ensureTailCowGroupConstraintSide(graph, source_staging, forward_prepared);
    try ensureTailCowGroupConstraintSide(graph, destination_staging, reverse_prepared);

    const old_forward_groups = shared.OldGroupChain.captureSide(source_staging);
    const old_reverse_groups = shared.OldGroupChain.captureSide(destination_staging);

    const forward_applied = try applyPreparedAppendSideTracked(graph, source_staging, forward_prepared, .fwd, &scratch);
    try insertForwardEdge(graph, forward_applied.block_idx, destination, relation, flags, edge_id.local);
    var source_publish_adj = common.nodeAdjForSide(source_staging.*, endpoints.source_flags, .fwd);
    repair.updateRepairDebtAfterEdgeMutation(graph, &source_publish_adj, source.index, .fwd, endpoints.source_flags.needs_repair_fwd);

    const reverse_applied = try applyPreparedAppendSideTracked(graph, destination_staging, reverse_prepared, .rev, &scratch);
    insertReverseEdge(graph, reverse_applied.block_idx, source);
    var destination_publish_adj = common.nodeAdjForSide(destination_staging.*, endpoints.destination_flags, .rev);
    repair.updateRepairDebtAfterEdgeMutation(graph, &destination_publish_adj, destination.index, .rev, endpoints.destination_flags.needs_repair_rev);

    scratch.disarm();
    shared.publishAdded(&endpoints, source, destination, source_publish_adj, destination_publish_adj);
    try shared.retireAdded(graph, forward_prepared, forward_applied, reverse_prepared, reverse_applied, old_forward_groups, old_reverse_groups);

    _ = graph.edge_count.fetchAdd(1, .release);
    rcu.bumpEpoch(graph);
    writer_guard.end();

    return edge_id;
}

pub fn addEdge(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !void {
    _ = try addEdgeImpl(graph, source, destination, relation, flags);
}

pub fn addEdgeWithId(graph: *graph_core.GraphCore, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) !types.EdgeId {
    if (!graph.multigraph_enabled) return error.UnsupportedOperation;
    return addEdgeImpl(graph, source, destination, relation, flags);
}
