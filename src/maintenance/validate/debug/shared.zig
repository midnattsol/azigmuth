const std = @import("std");
const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_adjacency_buffers = @import("../../../storage/node/adjacency_buffers.zig");
const common = @import("../common.zig");
const shape = @import("../shape.zig");
const sums = @import("../sums.zig");
const consistency = @import("../consistency.zig");
const violations = @import("../violations.zig");

pub const VisibleTotals = struct {
    fwd: u64 = 0,
    rev: u64 = 0,
};

pub const TrackingSets = struct {
    owned_forward_blocks: std.DynamicBitSetUnmanaged,
    owned_reverse_blocks: std.DynamicBitSetUnmanaged,
    free_forward_blocks: std.DynamicBitSetUnmanaged,
    free_reverse_blocks: std.DynamicBitSetUnmanaged,
    retired_forward_blocks: std.DynamicBitSetUnmanaged,
    retired_reverse_blocks: std.DynamicBitSetUnmanaged,
    segment_limit: u32,
    owned_segments: std.DynamicBitSetUnmanaged,
    free_segments: std.DynamicBitSetUnmanaged,
    retired_segments: std.DynamicBitSetUnmanaged,

    pub fn init(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) !TrackingSets {
        return .{
            .owned_forward_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire)),
            .owned_reverse_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire)),
            .free_forward_blocks = try violations.buildFreeBlockSet(graph, allocator, .fwd),
            .free_reverse_blocks = try violations.buildFreeBlockSet(graph, allocator, .rev),
            .retired_forward_blocks = try violations.buildRetiredBlockSet(graph, allocator, .fwd),
            .retired_reverse_blocks = try violations.buildRetiredBlockSet(graph, allocator, .rev),
            .segment_limit = @atomicLoad(u32, @constCast(&graph.segment_count), .acquire),
            .owned_segments = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.segment_count), .acquire)),
            .free_segments = try violations.buildFreeSegmentSet(graph, allocator),
            .retired_segments = try violations.buildRetiredSegmentSet(graph, allocator),
        };
    }

    pub fn deinit(self: *TrackingSets, allocator: std.mem.Allocator) void {
        self.owned_forward_blocks.deinit(allocator);
        self.owned_reverse_blocks.deinit(allocator);
        self.free_forward_blocks.deinit(allocator);
        self.free_reverse_blocks.deinit(allocator);
        self.retired_forward_blocks.deinit(allocator);
        self.retired_reverse_blocks.deinit(allocator);
        self.owned_segments.deinit(allocator);
        self.free_segments.deinit(allocator);
        self.retired_segments.deinit(allocator);
    }
};

fn appendBlockCountMismatches(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    forward_block_count: usize,
    reverse_block_count: usize,
) !void {
    const forward_side = common.sideAdjOf(adjacency, .fwd);
    const reverse_side = common.sideAdjOf(adjacency, .rev);
    const declared_forward_count: u32 = if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&forward_side)) 0 else adjacency.block_count_fwd;
    const declared_reverse_count: u32 = if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&reverse_side)) 0 else adjacency.block_count_rev;

    if (forward_block_count != declared_forward_count) {
        try list.append(allocator, .{ .block_count_segment_mismatch = .{ .node = node_id, .declared = declared_forward_count, .actual = @intCast(forward_block_count) } });
    }
    if (reverse_block_count != declared_reverse_count) {
        try list.append(allocator, .{ .block_count_segment_mismatch = .{ .node = node_id, .declared = declared_reverse_count, .actual = @intCast(reverse_block_count) } });
    }
}

fn trackSegmentsForSide(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    tracking: *TrackingSets,
    node_id: u32,
    first_segment: u32,
    segment_count: u16,
) !void {
    if (segment_count == 0) return;

    const end_segment = first_segment + segment_count;
    if (end_segment > tracking.segment_limit) {
        try list.append(allocator, .{ .blocksegment_chain_cycle = .{ .node = node_id, .segment = first_segment } });
        return;
    }

    for (first_segment..end_segment) |segment_idx_usize| {
        const segment_idx: u32 = @intCast(segment_idx_usize);
        if (tracking.owned_segments.isSet(segment_idx)) {
            try list.append(allocator, .{ .block_double_owned = .{ .block = segment_idx } });
        }
        tracking.owned_segments.set(segment_idx);
        if (tracking.free_segments.isSet(segment_idx)) {
            try list.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = segment_idx } });
        }
        if (tracking.retired_segments.isSet(segment_idx)) {
            try list.append(allocator, .{ .retired_block_reachable = .{ .block = segment_idx, .node = node_id } });
        }
    }
}

fn appendDegreeAndTombstoneViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    degree_fwd: u32,
    degree_rev: u32,
    visible_fwd: u64,
    visible_rev: u64,
) !void {
    if (!adjacency.flags.removed) {
        if (degree_fwd != visible_fwd) {
            try list.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(visible_fwd), .actual = @intCast(degree_fwd) } });
        }
        if (degree_rev != visible_rev) {
            try list.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(visible_rev), .actual = @intCast(degree_rev) } });
        }
        if (!adjacency.flags.needs_repair_fwd and common.forwardHasTombstone(graph, adjacency)) {
            try list.append(allocator, .{ .forward_tombstone_missing_repair_flag = .{ .node = node_id } });
        }
        if (!adjacency.flags.needs_repair_rev and common.reverseHasTombstone(graph, adjacency)) {
            try list.append(allocator, .{ .reverse_tombstone_missing_repair_flag = .{ .node = node_id } });
        }
        return;
    }

    if (adjacency.block_count_fwd != 0 or adjacency.segment_count_fwd != 0 or degree_fwd != 0) {
        try list.append(allocator, .{ .removed_node_has_outgoing = .{ .node = node_id } });
    }
    if (degree_rev != 0) {
        try list.append(allocator, .{ .removed_node_has_reverse_residual = .{ .node = node_id, .degree_rev = @intCast(degree_rev) } });
    }
    if (adjacency.block_count_rev != 0 or adjacency.segment_count_rev != 0) {
        try list.append(allocator, .{ .removed_node_has_reverse_storage = .{
            .node = node_id,
            .block_count_rev = adjacency.block_count_rev,
            .segment_count_rev = adjacency.segment_count_rev,
        } });
    }
    if (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev) {
        try list.append(allocator, .{ .removed_node_marked_for_repair = .{ .node = node_id } });
    }
}

fn appendLayoutViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
) !void {
    if (adjacency.flags.removed) return;

    const fwd_side = common.sideAdjOf(adjacency, .fwd);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&fwd_side)) {
        _ = shape.validateAdjacencyBlocksFast(graph, adjacency, .fwd) catch {
            try list.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = fwd_side.first_block, .slot = 0 } });
        };
    }

    if (adjacency.segment_count_fwd > constants.MAX_SEGMENTS_PER_NODE and !adjacency.flags.needs_repair_fwd) {
        try list.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
    }
    if (adjacency.segment_count_rev > constants.MAX_SEGMENTS_PER_NODE and !adjacency.flags.needs_repair_rev) {
        try list.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
    }
    try consistency.appendLayoutDebtViolations(graph, allocator, list, node_id, adjacency, .fwd);
    try consistency.appendLayoutDebtViolations(graph, allocator, list, node_id, adjacency, .rev);
}

pub fn appendNodeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    tracking: *TrackingSets,
    node_id: u32,
    adjacency: types.NodeAdj,
    degree_fwd: u32,
    degree_rev: u32,
) !VisibleTotals {
    var forward_blocks: std.ArrayList(common.TraversedBlock) = .empty;
    defer forward_blocks.deinit(allocator);
    var reverse_blocks: std.ArrayList(common.TraversedBlock) = .empty;
    defer reverse_blocks.deinit(allocator);

    try violations.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &forward_blocks, .fwd);
    try violations.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &reverse_blocks, .rev);
    try appendBlockCountMismatches(allocator, list, node_id, adjacency, forward_blocks.items.len, reverse_blocks.items.len);

    try trackSegmentsForSide(allocator, list, tracking, node_id, adjacency.first_segment_fwd, adjacency.segment_count_fwd);
    try trackSegmentsForSide(allocator, list, tracking, node_id, adjacency.first_segment_rev, adjacency.segment_count_rev);

    try violations.appendOwnershipAndShapeViolations(graph, allocator, list, &tracking.owned_forward_blocks, &tracking.free_forward_blocks, &tracking.retired_forward_blocks, node_id, forward_blocks.items, .fwd);
    try violations.appendOwnershipAndShapeViolations(graph, allocator, list, &tracking.owned_reverse_blocks, &tracking.free_reverse_blocks, &tracking.retired_reverse_blocks, node_id, reverse_blocks.items, .rev);

    if (!adjacency.flags.removed) {
        try consistency.appendForwardEdgeIdViolations(graph, allocator, list, node_id, adjacency);
        try consistency.appendForwardConsistencyViolations(graph, allocator, list, node_id, forward_blocks.items);
        try consistency.appendReverseConsistencyViolations(graph, allocator, list, node_id, reverse_blocks.items);
    }

    const visible_fwd = sums.sumVisibleAdjacency(graph, adjacency, .fwd);
    const visible_rev = sums.sumVisibleAdjacency(graph, adjacency, .rev);
    try appendDegreeAndTombstoneViolations(graph, allocator, list, node_id, adjacency, degree_fwd, degree_rev, visible_fwd, visible_rev);
    try appendLayoutViolations(graph, allocator, list, node_id, adjacency);

    if (adjacency.flags.removed) return .{};
    return .{ .fwd = visible_fwd, .rev = visible_rev };
}

pub fn appendSnapshotNodeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    node_id: u32,
    adjacency: types.NodeAdj,
    degree_fwd: u32,
    degree_rev: u32,
) !VisibleTotals {
    var forward_blocks: std.ArrayList(common.TraversedBlock) = .empty;
    defer forward_blocks.deinit(allocator);
    var reverse_blocks: std.ArrayList(common.TraversedBlock) = .empty;
    defer reverse_blocks.deinit(allocator);

    try violations.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &forward_blocks, .fwd);
    try violations.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &reverse_blocks, .rev);
    try appendBlockCountMismatches(allocator, list, node_id, adjacency, forward_blocks.items.len, reverse_blocks.items.len);

    if (!adjacency.flags.removed) {
        try consistency.appendForwardEdgeIdViolationsSnapshot(graph, allocator, list, node_id, adjacency);
        try consistency.appendForwardConsistencyViolations(graph, allocator, list, node_id, forward_blocks.items);
        try consistency.appendReverseConsistencyViolations(graph, allocator, list, node_id, reverse_blocks.items);
    }

    const visible_fwd = sums.sumVisibleAdjacency(graph, adjacency, .fwd);
    const visible_rev = sums.sumVisibleAdjacency(graph, adjacency, .rev);
    try appendDegreeAndTombstoneViolations(graph, allocator, list, node_id, adjacency, degree_fwd, degree_rev, visible_fwd, visible_rev);
    try appendLayoutViolations(graph, allocator, list, node_id, adjacency);

    if (adjacency.flags.removed) return .{};
    return .{ .fwd = visible_fwd, .rev = visible_rev };
}

pub fn appendRepairDebtAndReachabilityViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    tracking: *TrackingSets,
) !void {
    try consistency.appendRepairDebtViolations(graph, allocator, list);

    const fwd_limit = @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire);
    for (0..fwd_limit) |block_idx| {
        if (!tracking.owned_forward_blocks.isSet(block_idx) and
            !tracking.free_forward_blocks.isSet(block_idx) and
            !tracking.retired_forward_blocks.isSet(block_idx))
        {
            try list.append(allocator, .{ .unreachable_forward_block = .{ .block = @intCast(block_idx) } });
        }
    }

    const rev_limit = @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire);
    for (0..rev_limit) |block_idx| {
        if (!tracking.owned_reverse_blocks.isSet(block_idx) and
            !tracking.free_reverse_blocks.isSet(block_idx) and
            !tracking.retired_reverse_blocks.isSet(block_idx))
        {
            try list.append(allocator, .{ .unreachable_reverse_block = .{ .block = @intCast(block_idx) } });
        }
    }

    for (0..tracking.segment_limit) |segment_idx| {
        if (!tracking.owned_segments.isSet(segment_idx) and
            !tracking.free_segments.isSet(segment_idx) and
            !tracking.retired_segments.isSet(segment_idx))
        {
            try list.append(allocator, .{ .unreachable_segment = .{ .segment = @intCast(segment_idx) } });
        }
    }
}

pub fn appendTotalViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    totals: VisibleTotals,
    check_edge_count: bool,
) !void {
    if (totals.fwd != totals.rev) {
        try list.append(allocator, .{ .forward_reverse_count_mismatch = .{ .forward_total = totals.fwd, .reverse_total = totals.rev } });
    }
    if (check_edge_count and totals.fwd != graph.edge_count.load(.acquire)) {
        try list.append(allocator, .{ .edge_count_mismatch = .{ .expected = totals.fwd, .actual = graph.edge_count.load(.acquire) } });
    }
}
