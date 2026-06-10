const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const types = @import("../../core/types.zig");

pub const state_live_bit: u32 = 1 << 0;
pub const state_needs_repair_fwd_bit: u32 = 1 << 1;
pub const state_needs_repair_rev_bit: u32 = 1 << 2;

pub const SnapshotSide = types.SideAdj;

pub const CaptureStorage = struct {
    node_state: []u32,
    fwd_first_block: []u32,
    fwd_block_count: []u32,
    fwd_group_count: []u16,
    fwd_first_group: []u32,
    rev_first_block: []u32,
    rev_block_count: []u32,
    rev_group_count: []u16,
    rev_first_group: []u32,
    degree_fwd: []u32,
    degree_rev: []u32,
    live_node_count: usize,
};

const CapturedNodeData = struct {
    state: u32,
    fwd_side: SnapshotSide,
    rev_side: SnapshotSide,
    degree_fwd: u32,
    degree_rev: u32,
};

const empty_snapshot_side = SnapshotSide{
    .first_block = 0,
    .block_count = 0,
    .group_count = 0,
    .first_group = 0,
};

pub fn snapshotSide(side: types.SideAdj) SnapshotSide {
    return side;
}

pub fn sideAdjOfSnapshot(snapshot_side: SnapshotSide) types.SideAdj {
    return snapshot_side;
}

fn captureNode(graph: *const graph_core.GraphCore, node: types.NodeId) CapturedNodeData {
    while (true) {
        const before = node_access.loadPublishedMetaAtConst(graph, node);

        var state: u32 = 0;
        if (!before.removed) state |= state_live_bit;
        if (before.needs_repair_fwd) state |= state_needs_repair_fwd_bit;
        if (before.needs_repair_rev) state |= state_needs_repair_rev_bit;

        if (before.degree_fwd == 0 and before.degree_rev == 0 and !before.needs_repair_fwd and !before.needs_repair_rev) {
            const after_fast = node_access.loadPublishedMetaAtConst(graph, node);
            if (@as(u64, @bitCast(before)) != @as(u64, @bitCast(after_fast))) continue;
            return .{
                .state = state,
                .fwd_side = empty_snapshot_side,
                .rev_side = empty_snapshot_side,
                .degree_fwd = before.degree_fwd,
                .degree_rev = before.degree_rev,
            };
        }

        const fwd_side = node_access.publishedFwdFromMeta(graph, node, before);
        const rev_side = node_access.publishedRevFromMeta(graph, node, before);
        const degree_fwd = node_access.publishedFwdDegreeFromMetaAtConst(graph, node, before);
        const degree_rev = node_access.publishedRevDegreeFromMetaAtConst(graph, node, before);
        const after = node_access.loadPublishedMetaAtConst(graph, node);
        if (@as(u64, @bitCast(before)) != @as(u64, @bitCast(after))) continue;

        return .{
            .state = state,
            .fwd_side = snapshotSide(fwd_side),
            .rev_side = snapshotSide(rev_side),
            .degree_fwd = degree_fwd,
            .degree_rev = degree_rev,
        };
    }
}

pub fn captureStorage(core: *const graph_core.GraphCore, allocator: std.mem.Allocator) !CaptureStorage {
    const node_count = core.publishedNodeCount();
    const node_state = try allocator.alloc(u32, node_count);
    errdefer allocator.free(node_state);
    const fwd_first_block = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_first_block);
    const fwd_block_count = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_block_count);
    const fwd_group_count = try allocator.alloc(u16, node_count);
    errdefer allocator.free(fwd_group_count);
    const fwd_first_group = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_first_group);
    const rev_first_block = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_first_block);
    const rev_block_count = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_block_count);
    const rev_group_count = try allocator.alloc(u16, node_count);
    errdefer allocator.free(rev_group_count);
    const rev_first_group = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_first_group);
    const degree_fwd = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_fwd);
    const degree_rev = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_rev);

    var live_node_count: usize = 0;

    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        const captured = captureNode(core, .{ .index = node_idx });
        node_state[node_idx_usize] = captured.state;
        fwd_first_block[node_idx_usize] = captured.fwd_side.first_block;
        fwd_block_count[node_idx_usize] = captured.fwd_side.block_count;
        fwd_group_count[node_idx_usize] = captured.fwd_side.group_count;
        fwd_first_group[node_idx_usize] = captured.fwd_side.first_group;
        rev_first_block[node_idx_usize] = captured.rev_side.first_block;
        rev_block_count[node_idx_usize] = captured.rev_side.block_count;
        rev_group_count[node_idx_usize] = captured.rev_side.group_count;
        rev_first_group[node_idx_usize] = captured.rev_side.first_group;
        degree_fwd[node_idx_usize] = captured.degree_fwd;
        degree_rev[node_idx_usize] = captured.degree_rev;
        if ((captured.state & state_live_bit) != 0) live_node_count += 1;
    }

    return .{
        .node_state = node_state,
        .fwd_first_block = fwd_first_block,
        .fwd_block_count = fwd_block_count,
        .fwd_group_count = fwd_group_count,
        .fwd_first_group = fwd_first_group,
        .rev_first_block = rev_first_block,
        .rev_block_count = rev_block_count,
        .rev_group_count = rev_group_count,
        .rev_first_group = rev_first_group,
        .degree_fwd = degree_fwd,
        .degree_rev = degree_rev,
        .live_node_count = live_node_count,
    };
}
