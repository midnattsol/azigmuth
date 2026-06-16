const common = @import("common.zig");
const run_search = @import("run_search.zig");
const shape = @import("shape.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const snapshot_view = @import("../../query/snapshot/view.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const node_published = @import("../../storage/node/published.zig");
const logical = @import("logical.zig");

fn countVisibleEntriesInBlockSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    block_idx: u32,
    comptime side: common.Side,
) u64 {
    const block = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd),
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev),
    };
    const alive = switch (side) {
        .fwd => page_ops.blockAliveCount(graph, block_idx, .fwd),
        .rev => page_ops.blockAliveCount(graph, block_idx, .rev),
    };
    var total: u64 = 0;
    for (0..alive) |slot| {
        const candidate_idx = switch (side) {
            .fwd => block.destinations[slot],
            .rev => block.sources[slot],
        };
        if (candidate_idx < view.nodeCount() and view.isLiveIndex(candidate_idx)) total += 1;
    }
    return total;
}

fn countVisibleEntriesInTinySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    side_adj: types.SideAdj,
    comptime side: common.Side,
) u64 {
    const count = node_published.NodePublished.tinyCount(&side_adj);
    var total: u64 = 0;
    for (0..count) |entry_idx| {
        const candidate_idx = switch (side) {
            .fwd => page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd).entries[entry_idx].destination,
            .rev => page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev).sources[entry_idx],
        };
        if (candidate_idx < view.nodeCount() and view.isLiveIndex(candidate_idx)) total += 1;
    }
    return total;
}

fn sumVisibleAdjacencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    adjacency: types.NodeAdj,
    comptime side: common.Side,
) u64 {
    if (adjacency.flags.removed) return 0;
    const side_adj = common.sideAdjOf(adjacency, side);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        return countVisibleEntriesInTinySnapshot(graph, view, side_adj, side);
    }

    const SumContext = struct {
        view: *const snapshot_view.CapturedGraphView,
        total: u64 = 0,
    };

    var ctx = SumContext{ .view = view };
    common.forEachRunInAdj(graph, adjacency, side, &ctx, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: *SumContext,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                inner_ctx.total += countVisibleEntriesInBlockSnapshot(inner_graph, inner_ctx.view, @intCast(block_idx_usize), side);
            }
        }
    }.callback) catch return ctx.total;
    return ctx.total;
}

fn hasTombstoneSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    adjacency: types.NodeAdj,
    comptime side: common.Side,
) bool {
    if (adjacency.flags.removed) return false;
    const side_adj = common.sideAdjOf(adjacency, side);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const count = node_published.NodePublished.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            const candidate_idx = switch (side) {
                .fwd => page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd).entries[entry_idx].destination,
                .rev => page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev).sources[entry_idx],
            };
            if (candidate_idx < view.nodeCount() and !view.isLiveIndex(candidate_idx)) return true;
        }
        return false;
    }

    const TombstoneContext = struct {
        view: *const snapshot_view.CapturedGraphView,
    };

    var ctx = TombstoneContext{ .view = view };
    common.forEachRunInAdj(graph, adjacency, side, &ctx, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: *TombstoneContext,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block_idx: u32 = @intCast(block_idx_usize);
                const block = switch (side) {
                    .fwd => page_ops.edgeBlockAtConst(inner_graph, block_idx, .fwd),
                    .rev => page_ops.edgeBlockAtConst(inner_graph, block_idx, .rev),
                };
                const alive = switch (side) {
                    .fwd => page_ops.blockAliveCount(inner_graph, block_idx, .fwd),
                    .rev => page_ops.blockAliveCount(inner_graph, block_idx, .rev),
                };
                for (0..alive) |slot| {
                    const candidate_idx = switch (side) {
                        .fwd => block.destinations[slot],
                        .rev => block.sources[slot],
                    };
                    if (candidate_idx < inner_ctx.view.nodeCount() and !inner_ctx.view.isLiveIndex(candidate_idx)) return error.TombstoneFound;
                }
            }
        }
    }.callback) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return false;
}

fn forwardHasTombstoneSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    adjacency: types.NodeAdj,
) bool {
    return hasTombstoneSnapshot(graph, view, adjacency, .fwd);
}

fn reverseHasTombstoneSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    adjacency: types.NodeAdj,
) bool {
    return hasTombstoneSnapshot(graph, view, adjacency, .rev);
}

fn adjacencyContainsSnapshot(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    target: u32,
    comptime side: common.Side,
) bool {
    return run_search.adjacencyContains(graph, adjacency, target, side);
}

fn countTargetMatchesSnapshot(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
    target: u32,
    comptime side: common.Side,
) u32 {
    return run_search.countTargetMatches(graph, adjacency, target, side);
}

fn validateForwardEdgeIdsSnapshot(
    graph: *const graph_core.GraphCore,
    adjacency: types.NodeAdj,
) !void {
    if (!graph.multigraph_enabled) return;
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;
    const side_adj = common.sideAdjOf(adjacency, .fwd);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
        const count = node_published.NodePublished.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            if (slot.entries[entry_idx].edge_id == 0) return error.CorruptGraph;
        }
        return;
    }

    try common.forEachRunInAdj(graph, adjacency, .fwd, {}, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            _: void,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block_idx: u32 = @intCast(block_idx_usize);
                const id_block = page_ops.edgeBlockFwdIdsAtConst(inner_graph, block_idx);
                const alive_count = @min(page_ops.blockAliveCount(inner_graph, block_idx, .fwd), constants.EDGES_PER_BLOCK);
                for (0..alive_count) |slot| {
                    if (id_block.ids[slot] == 0) return error.CorruptGraph;
                }
            }
        }
    }.callback);
}

fn validateForwardConsistencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    source_idx: u32,
    adjacency: types.NodeAdj,
) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;
    const side_adj = common.sideAdjOf(adjacency, .fwd);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd);
        const count = node_published.NodePublished.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            const destination_idx = slot.entries[entry_idx].destination;
            if (destination_idx >= view.nodeCount()) return error.CorruptGraph;
            const destination_adjacency = view.adjacency(destination_idx);
            if (destination_adjacency.flags.removed) continue;
            if (graph.multigraph_enabled) {
                const forward_count = countTargetMatchesSnapshot(graph, adjacency, destination_idx, .fwd);
                const reverse_count = countTargetMatchesSnapshot(graph, destination_adjacency, source_idx, .rev);
                if (forward_count != reverse_count) return error.CorruptGraph;
            } else if (!adjacencyContainsSnapshot(graph, destination_adjacency, source_idx, .rev)) {
                return error.CorruptGraph;
            }
        }
        return;
    }

    const ForwardContext = struct {
        view: *const snapshot_view.CapturedGraphView,
        source_idx: u32,
        adjacency: types.NodeAdj,
    };

    var ctx = ForwardContext{ .view = view, .source_idx = source_idx, .adjacency = adjacency };
    try common.forEachRunInAdj(graph, adjacency, .fwd, &ctx, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: *ForwardContext,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .fwd);
                const alive = @min(page_ops.blockAliveCount(inner_graph, @intCast(block_idx_usize), .fwd), constants.EDGES_PER_BLOCK);
                for (0..alive) |slot| {
                    const destination_idx = block.destinations[slot];
                    if (destination_idx >= inner_ctx.view.nodeCount()) return error.CorruptGraph;

                    const destination_adjacency = inner_ctx.view.adjacency(destination_idx);
                    if (destination_adjacency.flags.removed) continue;
                    if (inner_graph.multigraph_enabled) {
                        const forward_count = countTargetMatchesSnapshot(inner_graph, inner_ctx.adjacency, destination_idx, .fwd);
                        const reverse_count = countTargetMatchesSnapshot(inner_graph, destination_adjacency, inner_ctx.source_idx, .rev);
                        if (forward_count != reverse_count) return error.CorruptGraph;
                    } else if (!adjacencyContainsSnapshot(inner_graph, destination_adjacency, inner_ctx.source_idx, .rev)) {
                        return error.CorruptGraph;
                    }
                }
            }
        }
    }.callback);
}

fn validateReverseConsistencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    destination_idx: u32,
    adjacency: types.NodeAdj,
) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .rev) == 0) return;
    const side_adj = common.sideAdjOf(adjacency, .rev);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev);
        const count = node_published.NodePublished.tinyCount(&side_adj);
        for (0..count) |entry_idx| {
            const source_idx = slot.sources[entry_idx];
            if (source_idx >= view.nodeCount()) return error.CorruptGraph;
            const source_adjacency = view.adjacency(source_idx);
            if (source_adjacency.flags.removed) continue;
            if (!adjacencyContainsSnapshot(graph, source_adjacency, destination_idx, .fwd)) return error.CorruptGraph;
        }
        return;
    }

    const ReverseContext = struct {
        view: *const snapshot_view.CapturedGraphView,
        destination_idx: u32,
    };

    var ctx = ReverseContext{ .view = view, .destination_idx = destination_idx };
    try common.forEachRunInAdj(graph, adjacency, .rev, &ctx, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_ctx: *ReverseContext,
            start: u32,
            count: u32,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .rev);
                const alive = @min(page_ops.blockAliveCount(inner_graph, @intCast(block_idx_usize), .rev), constants.EDGES_PER_BLOCK);
                for (0..alive) |slot| {
                    const source_idx = block.sources[slot];
                    if (source_idx >= inner_ctx.view.nodeCount()) return error.CorruptGraph;

                    const source_adjacency = inner_ctx.view.adjacency(source_idx);
                    if (source_adjacency.flags.removed) continue;
                    if (!adjacencyContainsSnapshot(inner_graph, source_adjacency, inner_ctx.destination_idx, .fwd)) {
                        return error.CorruptGraph;
                    }
                }
            }
        }
    }.callback);
}

pub fn validateSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
) !void {
    const node_count = view.nodeCount();
    var total_visible_forward: u64 = 0;
    var total_visible_reverse: u64 = 0;

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        const adjacency = view.adjacency(node_idx);

        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .fwd);
        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .rev);
        const fwd_visible = sumVisibleAdjacencySnapshot(graph, view, adjacency, .fwd);
        const rev_visible = sumVisibleAdjacencySnapshot(graph, view, adjacency, .rev);
        total_visible_forward += fwd_visible;
        total_visible_reverse += rev_visible;
        try shape.validateOccupancyFast(graph, adjacency, .fwd);
        try shape.validateOccupancyFast(graph, adjacency, .rev);
        try validateForwardEdgeIdsSnapshot(graph, adjacency);
        try validateForwardConsistencySnapshot(graph, view, node_idx, adjacency);
        try validateReverseConsistencySnapshot(graph, view, node_idx, adjacency);

        try logical.validateLiveNodeState(
            adjacency,
            view.degree_fwd[node_idx],
            view.degree_rev[node_idx],
            fwd_visible,
            rev_visible,
            forwardHasTombstoneSnapshot(graph, view, adjacency),
            reverseHasTombstoneSnapshot(graph, view, adjacency),
            true,
        );
    }

    try logical.validateVisibleTotals(total_visible_forward, total_visible_reverse);
}
