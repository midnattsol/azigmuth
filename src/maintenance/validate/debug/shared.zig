const std = @import("std");
const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const common = @import("../common.zig");
const shape = @import("../shape.zig");
const sums = @import("../sums.zig");
const consistency = @import("../consistency.zig");
const v = @import("../violations.zig");

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
    group_limit: u32,
    owned_groups: std.DynamicBitSetUnmanaged,
    free_groups: std.DynamicBitSetUnmanaged,
    retired_groups: std.DynamicBitSetUnmanaged,

    pub fn init(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) !TrackingSets {
        return .{
            .owned_forward_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire)),
            .owned_reverse_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire)),
            .free_forward_blocks = try v.buildFreeBlockSet(graph, allocator, .fwd),
            .free_reverse_blocks = try v.buildFreeBlockSet(graph, allocator, .rev),
            .retired_forward_blocks = try v.buildRetiredBlockSet(graph, allocator, .fwd),
            .retired_reverse_blocks = try v.buildRetiredBlockSet(graph, allocator, .rev),
            .group_limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire),
            .owned_groups = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.group_count), .acquire)),
            .free_groups = try v.buildFreeGroupSet(graph, allocator),
            .retired_groups = try v.buildRetiredGroupSet(graph, allocator),
        };
    }

    pub fn deinit(self: *TrackingSets, allocator: std.mem.Allocator) void {
        self.owned_forward_blocks.deinit(allocator);
        self.owned_reverse_blocks.deinit(allocator);
        self.free_forward_blocks.deinit(allocator);
        self.free_reverse_blocks.deinit(allocator);
        self.retired_forward_blocks.deinit(allocator);
        self.retired_reverse_blocks.deinit(allocator);
        self.owned_groups.deinit(allocator);
        self.free_groups.deinit(allocator);
        self.retired_groups.deinit(allocator);
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
    const declared_forward_count: u32 = if (node_published.NodePublished.isTiny(&forward_side)) 0 else adjacency.block_count_fwd;
    const declared_reverse_count: u32 = if (node_published.NodePublished.isTiny(&reverse_side)) 0 else adjacency.block_count_rev;

    if (forward_block_count != declared_forward_count) {
        try list.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = declared_forward_count, .actual = @intCast(forward_block_count) } });
    }
    if (reverse_block_count != declared_reverse_count) {
        try list.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = declared_reverse_count, .actual = @intCast(reverse_block_count) } });
    }
}

fn trackGroupsForSide(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Violation),
    tracking: *TrackingSets,
    node_id: u32,
    first_group: u32,
    group_count: u16,
) !void {
    if (group_count == 0) return;

    const end_group = first_group + group_count;
    if (end_group > tracking.group_limit) {
        try list.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = first_group } });
        return;
    }

    for (first_group..end_group) |group_idx_usize| {
        const group_idx: u32 = @intCast(group_idx_usize);
        if (tracking.owned_groups.isSet(group_idx)) {
            try list.append(allocator, .{ .block_double_owned = .{ .block = group_idx } });
        }
        tracking.owned_groups.set(group_idx);
        if (tracking.free_groups.isSet(group_idx)) {
            try list.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = group_idx } });
        }
        if (tracking.retired_groups.isSet(group_idx)) {
            try list.append(allocator, .{ .retired_block_reachable = .{ .block = group_idx, .node = node_id } });
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

    if (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or degree_fwd != 0) {
        try list.append(allocator, .{ .removed_node_has_outgoing = .{ .node = node_id } });
    }
    if (degree_rev != 0) {
        try list.append(allocator, .{ .removed_node_has_reverse_residual = .{ .node = node_id, .degree_rev = @intCast(degree_rev) } });
    }
    if (adjacency.block_count_rev != 0 or adjacency.group_count_rev != 0) {
        try list.append(allocator, .{ .removed_node_has_reverse_storage = .{
            .node = node_id,
            .block_count_rev = adjacency.block_count_rev,
            .group_count_rev = adjacency.group_count_rev,
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
    if (node_published.NodePublished.isTiny(&fwd_side)) {
        _ = shape.validateAdjacencyBlocksFast(graph, adjacency, .fwd) catch {
            try list.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = fwd_side.first_block, .slot = 0 } });
        };
    }

    if (adjacency.group_count_fwd > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_fwd) {
        try list.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
    }
    if (adjacency.group_count_rev > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_rev) {
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

    try v.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &forward_blocks, .fwd);
    try v.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &reverse_blocks, .rev);
    try appendBlockCountMismatches(allocator, list, node_id, adjacency, forward_blocks.items.len, reverse_blocks.items.len);

    try trackGroupsForSide(allocator, list, tracking, node_id, adjacency.first_group_fwd, adjacency.group_count_fwd);
    try trackGroupsForSide(allocator, list, tracking, node_id, adjacency.first_group_rev, adjacency.group_count_rev);


    try v.appendOwnershipAndShapeViolations(graph, allocator, list, &tracking.owned_forward_blocks, &tracking.free_forward_blocks, &tracking.retired_forward_blocks, node_id, forward_blocks.items, .fwd);
    try v.appendOwnershipAndShapeViolations(graph, allocator, list, &tracking.owned_reverse_blocks, &tracking.free_reverse_blocks, &tracking.retired_reverse_blocks, node_id, reverse_blocks.items, .rev);

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

    try v.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &forward_blocks, .fwd);
    try v.collectAdjacencyBlocks(graph, allocator, list, node_id, adjacency, &reverse_blocks, .rev);
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
    for (0..fwd_limit) |block_index| {
        if (!tracking.owned_forward_blocks.isSet(block_index) and
            !tracking.free_forward_blocks.isSet(block_index) and
            !tracking.retired_forward_blocks.isSet(block_index))
        {
            try list.append(allocator, .{ .unreachable_forward_block = .{ .block = @intCast(block_index) } });
        }
    }

    const rev_limit = @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire);
    for (0..rev_limit) |block_index| {
        if (!tracking.owned_reverse_blocks.isSet(block_index) and
            !tracking.free_reverse_blocks.isSet(block_index) and
            !tracking.retired_reverse_blocks.isSet(block_index))
        {
            try list.append(allocator, .{ .unreachable_reverse_block = .{ .block = @intCast(block_index) } });
        }
    }

    for (0..tracking.group_limit) |group_index| {
        if (!tracking.owned_groups.isSet(group_index) and
            !tracking.free_groups.isSet(group_index) and
            !tracking.retired_groups.isSet(group_index))
        {
            try list.append(allocator, .{ .unreachable_group = .{ .group = @intCast(group_index) } });
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
