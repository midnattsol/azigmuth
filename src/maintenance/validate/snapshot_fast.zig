const common = @import("common.zig");
const run_search = @import("run_search.zig");
const shape = @import("shape.zig");
const graph_core = @import("../../core/graph_core.zig");
const read_session = @import("../../query/read_session.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const constants = @import("../../core/constants.zig");

fn countVisibleEntriesInBlockSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    block_idx: u32,
    comptime side: common.Side,
) u64 {
    const block = switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd),
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev),
    };
    const live = @popCount(block.mask);
    var total: u64 = 0;
    for (0..live) |slot| {
        const candidate_idx = switch (side) {
            .fwd => block.edges[slot].destination,
            .rev => block.sources[slot],
        };
        if (candidate_idx < view.nodeCount() and view.isLiveIndex(candidate_idx)) total += 1;
    }
    return total;
}

fn sumVisibleAdjacencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    adjacency: types.NodeAdj,
    comptime side: common.Side,
) u64 {
    if (adjacency.flags.removed) return 0;

    const SumContext = struct {
        view: *const read_session.CapturedGraphView,
        total: u64 = 0,
    };

    var context = SumContext{ .view = view };
    common.forEachRunInAdj(graph, adjacency, side, &context, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_context: *SumContext,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                inner_context.total += countVisibleEntriesInBlockSnapshot(inner_graph, inner_context.view, @intCast(block_idx_usize), side);
            }
        }
    }.callback) catch return context.total;
    return context.total;
}

fn forwardHasTombstoneSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    adjacency: types.NodeAdj,
) bool {
    if (adjacency.flags.removed) return false;

    const TombstoneContext = struct {
        view: *const read_session.CapturedGraphView,
    };

    var context = TombstoneContext{ .view = view };
    common.forEachRunInAdj(graph, adjacency, .fwd, &context, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_context: *TombstoneContext,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    const destination_idx = block.edges[slot].destination;
                    if (destination_idx < inner_context.view.nodeCount() and !inner_context.view.isLiveIndex(destination_idx)) return error.TombstoneFound;
                }
            }
        }
    }.callback) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return false;
}

fn reverseHasTombstoneSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    adjacency: types.NodeAdj,
) bool {
    if (adjacency.flags.removed) return false;

    const TombstoneContext = struct {
        view: *const read_session.CapturedGraphView,
    };

    var context = TombstoneContext{ .view = view };
    common.forEachRunInAdj(graph, adjacency, .rev, &context, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_context: *TombstoneContext,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    const source_idx = block.sources[slot];
                    if (source_idx < inner_context.view.nodeCount() and !inner_context.view.isLiveIndex(source_idx)) return error.TombstoneFound;
                }
            }
        }
    }.callback) catch |err| {
        if (err == error.TombstoneFound) return true;
        return false;
    };
    return false;
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

    try common.forEachRunInAdj(graph, adjacency, .fwd, {}, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            _: void,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block_idx: u32 = @intCast(block_idx_usize);
                const id_block = page_ops.edgeBlockFwdIdsAtConst(inner_graph, block_idx);
                const live_count = @popCount(page_ops.edgeBlockAtConst(inner_graph, block_idx, .fwd).mask);
                for (0..live_count) |slot| {
                    if (id_block.ids[slot] == 0) return error.CorruptGraph;
                }
            }
        }
    }.callback);
}

fn validateForwardConsistencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    source_idx: u32,
    adjacency: types.NodeAdj,
) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .fwd) == 0) return;

    const ForwardContext = struct {
        view: *const read_session.CapturedGraphView,
        source_idx: u32,
        adjacency: types.NodeAdj,
    };

    var context = ForwardContext{ .view = view, .source_idx = source_idx, .adjacency = adjacency };
    try common.forEachRunInAdj(graph, adjacency, .fwd, &context, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_context: *ForwardContext,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .fwd);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    const destination_idx = block.edges[slot].destination;
                    if (destination_idx >= inner_context.view.nodeCount()) return error.CorruptGraph;

                    const destination_adjacency = inner_context.view.adjacency(destination_idx);
                    if (destination_adjacency.flags.removed) continue;
                    if (inner_graph.multigraph_enabled) {
                        const forward_count = countTargetMatchesSnapshot(inner_graph, inner_context.adjacency, destination_idx, .fwd);
                        const reverse_count = countTargetMatchesSnapshot(inner_graph, destination_adjacency, inner_context.source_idx, .rev);
                        if (forward_count != reverse_count) return error.CorruptGraph;
                    } else if (!adjacencyContainsSnapshot(inner_graph, destination_adjacency, inner_context.source_idx, .rev)) {
                        return error.CorruptGraph;
                    }
                }
            }
        }
    }.callback);
}

fn validateReverseConsistencySnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
    destination_idx: u32,
    adjacency: types.NodeAdj,
) !void {
    if (adjacency.flags.removed) return;
    if (common.blockCount(adjacency, .rev) == 0) return;

    const ReverseContext = struct {
        view: *const read_session.CapturedGraphView,
        destination_idx: u32,
    };

    var context = ReverseContext{ .view = view, .destination_idx = destination_idx };
    try common.forEachRunInAdj(graph, adjacency, .rev, &context, struct {
        fn callback(
            inner_graph: *const graph_core.GraphCore,
            inner_context: *ReverseContext,
            start: u32,
            count: u16,
            _: bool,
        ) !void {
            for (start..start + count) |block_idx_usize| {
                const block = page_ops.edgeBlockAtConst(inner_graph, @intCast(block_idx_usize), .rev);
                const live = @popCount(block.mask);
                for (0..live) |slot| {
                    const source_idx = block.sources[slot];
                    if (source_idx >= inner_context.view.nodeCount()) return error.CorruptGraph;

                    const source_adjacency = inner_context.view.adjacency(source_idx);
                    if (source_adjacency.flags.removed) continue;
                    if (!adjacencyContainsSnapshot(inner_graph, source_adjacency, inner_context.destination_idx, .fwd)) {
                        return error.CorruptGraph;
                    }
                }
            }
        }
    }.callback);
}

pub fn validateSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const read_session.CapturedGraphView,
) !void {
    const node_count = view.nodeCount();
    var total_visible_forward: u64 = 0;
    var total_visible_reverse: u64 = 0;

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        const adjacency = view.adjacency(node_idx);

        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .fwd);
        _ = try shape.validateAdjacencyBlocksFast(graph, adjacency, .rev);
        total_visible_forward += sumVisibleAdjacencySnapshot(graph, view, adjacency, .fwd);
        total_visible_reverse += sumVisibleAdjacencySnapshot(graph, view, adjacency, .rev);
        try shape.validateOccupancyFast(graph, adjacency, .fwd);
        try shape.validateOccupancyFast(graph, adjacency, .rev);
        try validateForwardEdgeIdsSnapshot(graph, adjacency);
        try validateForwardConsistencySnapshot(graph, view, node_idx, adjacency);
        try validateReverseConsistencySnapshot(graph, view, node_idx, adjacency);

        if (adjacency.flags.removed) {
            if (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or view.degree_fwd[node_idx] != 0) return error.CorruptGraph;
            if (view.degree_rev[node_idx] != 0) return error.CorruptGraph;
            if (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev) return error.CorruptGraph;
        }

        const fwd_visible = sumVisibleAdjacencySnapshot(graph, view, adjacency, .fwd);
        const rev_visible = sumVisibleAdjacencySnapshot(graph, view, adjacency, .rev);
        if (!adjacency.flags.removed) {
            if (view.degree_fwd[node_idx] != fwd_visible) return error.CorruptGraph;
            if (view.degree_rev[node_idx] != rev_visible) return error.CorruptGraph;
            if (!adjacency.flags.needs_repair_fwd and forwardHasTombstoneSnapshot(graph, view, adjacency)) return error.CorruptGraph;
            if (!adjacency.flags.needs_repair_rev and reverseHasTombstoneSnapshot(graph, view, adjacency)) return error.CorruptGraph;
            if (adjacency.group_count_fwd > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_fwd) return error.CorruptGraph;
            if (adjacency.group_count_rev > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_rev) return error.CorruptGraph;
        }
    }

    if (total_visible_forward != total_visible_reverse) return error.CorruptGraph;
}
