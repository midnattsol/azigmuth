const std = @import("std");
const sorted_rebuild = @import("sorted_rebuild.zig");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const adjacency = @import("../../adjacency/mod.zig");
const node_adjacency_buffers = @import("../../storage/node/adjacency_buffers.zig");
const node_tiny = @import("../../storage/node/tiny.zig");
const rcu = @import("../../concurrency/rcu.zig");
const node_validity = @import("../../core/node_validity.zig");
const side_adj = @import("../../adjacency/side_ops.zig");
const mutation_common = @import("../../mutation/common.zig");
const debt_mod = @import("debt.zig");
const side_rebuild_apply = @import("side_rebuild_apply.zig");

const ReverseSourceMatchCount = struct {
    source_idx: u32,
    total: usize = 0,
};

fn countReverseSourceMatch(_: *const graph_core.GraphCore, count: *ReverseSourceMatchCount, source_idx: u32) !void {
    if (source_idx == count.source_idx) count.total += 1;
}

fn countAliveTinyForwardEntries(
    graph: *const graph_core.GraphCore,
    published_side: types.SideAdj,
) !u16 {
    var alive_after: u16 = 0;
    try side_adj.forEachForwardEntryInSide(graph, published_side, &alive_after, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_alive_after: *u16, entry: side_adj.ForwardEntryView) !void {
            if (entry.destination < inner_graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(inner_graph, entry.destination)) {
                inner_alive_after.* += 1;
            }
        }
    }.callback);
    return alive_after;
}

fn fillAliveTinyForwardEntries(
    graph: *const graph_core.GraphCore,
    published_side: types.SideAdj,
    slot: *node_tiny.TinyFwdSlot,
) !u16 {
    const FillContext = struct {
        slot: *node_tiny.TinyFwdSlot,
        write_idx: u16 = 0,
    };

    var fill = FillContext{ .slot = slot };
    try side_adj.forEachForwardEntryInSide(graph, published_side, &fill, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_fill: *FillContext, entry: side_adj.ForwardEntryView) !void {
            if (entry.destination >= inner_graph.publishedNodeCount() or node_validity.isNodeRemovedIndex(inner_graph, entry.destination)) return;
            inner_fill.slot.entries[inner_fill.write_idx] = .{
                .destination = entry.destination,
                .relation = entry.relation,
                .flags = entry.flags,
                .edge_id = entry.edge_id,
                .prop_row = entry.prop_row,
            };
            inner_fill.write_idx += 1;
        }
    }.callback);
    return fill.write_idx;
}

fn clearForwardSide(adj: *types.NodeAdj) void {
    adj.first_block_fwd = 0;
    adj.block_count_fwd = 0;
    adj.segment_count_fwd = 0;
    adj.first_segment_fwd = 0;
}

fn writeTinyForwardSide(adj: *types.NodeAdj, slot_idx: u32, alive_count: u16) void {
    adj.first_block_fwd = slot_idx;
    adj.block_count_fwd = node_adjacency_buffers.TINY_MODE_BIT | alive_count;
    adj.segment_count_fwd = 0;
    adj.first_segment_fwd = 0;
}

pub const ForwardTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    alive_after: usize,
    removed_count: usize,
    /// Rows of dropped forward entries; retire after publish, then deinit.
    dropped_prop_rows: std.ArrayList(u32) = .empty,
};

pub const ReverseTombstoneCompaction = struct {
    staging_adj: types.NodeAdj,
    alive_after: usize,
};

fn collectDroppedTinyForwardRows(
    graph: *const graph_core.GraphCore,
    published_side: types.SideAdj,
    dropped: *std.ArrayList(u32),
) !void {
    if (!graph.edge_properties_enabled) return;
    try side_adj.forEachForwardEntryInSide(graph, published_side, dropped, struct {
        fn callback(inner_graph: *const graph_core.GraphCore, inner_dropped: *std.ArrayList(u32), entry: side_adj.ForwardEntryView) !void {
            const keep = entry.destination < inner_graph.publishedNodeCount() and !node_validity.isNodeRemovedIndex(inner_graph, entry.destination);
            if (!keep and entry.prop_row != 0) try inner_dropped.append(inner_graph.allocator, entry.prop_row);
        }
    }.callback);
}

fn rebuildTinyForwardAlive(
    graph: *graph_core.GraphCore,
    node_idx: u32,
    published_adj: types.NodeAdj,
    allocs: *mutation_common.MutationScratch,
) !ForwardTombstoneCompaction {
    const published_side = side_adj.sideAdjOfNode(published_adj, .fwd);
    const alive_after = try countAliveTinyForwardEntries(graph, published_side);

    var dropped_rows: std.ArrayList(u32) = .empty;
    errdefer dropped_rows.deinit(graph.allocator);
    try collectDroppedTinyForwardRows(graph, published_side, &dropped_rows);

    var staging_adj = published_adj;
    const original_count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&published_side);
    if (alive_after == 0) {
        clearForwardSide(&staging_adj);
        debt_mod.updateRepairDebt(graph, &staging_adj, node_idx, .fwd);
        return .{ .staging_adj = staging_adj, .alive_after = 0, .removed_count = original_count, .dropped_prop_rows = dropped_rows };
    }

    const new_slot_idx = try allocs.allocTinySlotRaw(graph, .fwd);
    const new_block = page_ops.tinySlotAt(graph, new_slot_idx, .fwd);
    const copied_alive_count = try fillAliveTinyForwardEntries(graph, published_side, new_block);

    writeTinyForwardSide(&staging_adj, new_slot_idx, copied_alive_count);
    debt_mod.updateRepairDebt(graph, &staging_adj, node_idx, .fwd);
    return .{ .staging_adj = staging_adj, .alive_after = copied_alive_count, .removed_count = original_count - copied_alive_count, .dropped_prop_rows = dropped_rows };
}

pub fn rebuildForwardAlive(
    graph: *graph_core.GraphCore,
    node_idx: u32,
    published_adj: types.NodeAdj,
    allocs: *mutation_common.MutationScratch,
) !ForwardTombstoneCompaction {
    const published_side = side_adj.sideAdjOfNode(published_adj, .fwd);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&published_side)) return rebuildTinyForwardAlive(graph, node_idx, published_adj, allocs);

    var result = try sorted_rebuild.sortedRebuildForward(
        graph,
        published_adj.first_block_fwd,
        published_adj.block_count_fwd,
        published_adj.segment_count_fwd,
        published_adj.first_segment_fwd,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);
    errdefer result.dropped_prop_rows.deinit(graph.allocator);

    const rebuilt_side = side_rebuild_apply.adoptSortedRebuildSide(graph, .fwd, &result, allocs) catch |err| {
        for (result.new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, .fwd);
        return err;
    };

    var staging_adj = published_adj;
    staging_adj.first_block_fwd = rebuilt_side.first_block;
    staging_adj.block_count_fwd = rebuilt_side.block_count;
    staging_adj.segment_count_fwd = rebuilt_side.segment_count;
    staging_adj.first_segment_fwd = rebuilt_side.first_segment;
    debt_mod.updateRepairDebt(graph, &staging_adj, node_idx, .fwd);

    const dropped_rows = result.dropped_prop_rows;
    result.dropped_prop_rows = .empty;
    return .{ .staging_adj = staging_adj, .alive_after = result.alive_after, .removed_count = 0, .dropped_prop_rows = dropped_rows };
}

pub fn countReverseMatches(
    graph: *const graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    source_idx: u32,
) !usize {
    const side_view: types.SideAdj = .{
        .first_block = first_block,
        .block_count = block_count,
        .segment_count = segment_count,
        .first_segment = first_segment,
    };
    var count = ReverseSourceMatchCount{ .source_idx = source_idx };
    try side_adj.forEachNodeIdInSide(graph, side_view, .rev, &count, countReverseSourceMatch);
    return count.total;
}

pub fn prepareReverseDrop(
    graph: *graph_core.GraphCore,
    first_block: u32,
    block_count: u32,
    segment_count: u16,
    first_segment: u32,
    source_idx: u32,
    allocator: std.mem.Allocator,
) !sorted_rebuild.SortedRebuildResult {
    const matches = try countReverseMatches(graph, first_block, block_count, segment_count, first_segment, source_idx);
    if (!graph.multigraph_enabled and matches != 1) return error.CorruptGraph;
    if (matches == 0) return error.CorruptGraph;
    return sorted_rebuild.sortedRebuildReverse(graph, first_block, block_count, segment_count, first_segment, source_idx, allocator);
}

pub fn rebuildReverseDrop(
    graph: *graph_core.GraphCore,
    destination_idx: u32,
    published_adj: types.NodeAdj,
    source_idx: u32,
    allocs: *mutation_common.MutationScratch,
) !ReverseTombstoneCompaction {
    var result = try prepareReverseDrop(
        graph,
        published_adj.first_block_rev,
        published_adj.block_count_rev,
        published_adj.segment_count_rev,
        published_adj.first_segment_rev,
        source_idx,
        graph.allocator,
    );
    defer result.new_blocks.deinit(graph.allocator);
    defer result.dropped_prop_rows.deinit(graph.allocator);

    const rebuilt_side = side_rebuild_apply.adoptSortedRebuildSide(graph, .rev, &result, allocs) catch |err| {
        for (result.new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, .rev);
        return err;
    };

    var staging_adj = published_adj;
    staging_adj.first_block_rev = rebuilt_side.first_block;
    staging_adj.block_count_rev = rebuilt_side.block_count;
    staging_adj.segment_count_rev = rebuilt_side.segment_count;
    staging_adj.first_segment_rev = rebuilt_side.first_segment;
    debt_mod.updateRepairDebt(graph, &staging_adj, destination_idx, .rev);

    return .{ .staging_adj = staging_adj, .alive_after = result.alive_after };
}
