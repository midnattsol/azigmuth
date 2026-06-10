const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const snapshot_capture = @import("capture.zig");

const state_live_bit = snapshot_capture.state_live_bit;
const state_needs_repair_fwd_bit = snapshot_capture.state_needs_repair_fwd_bit;
const state_needs_repair_rev_bit = snapshot_capture.state_needs_repair_rev_bit;

pub const SnapshotSide = snapshot_capture.SnapshotSide;

pub const CapturedGraphView = struct {
    core: *const graph_core.GraphCore,
    node_state: []u32,
    fwd_side: []SnapshotSide,
    rev_side: []SnapshotSide,
    degree_fwd: []u32,
    degree_rev: []u32,
    live_node_count: usize,

    pub fn deinit(self: *CapturedGraphView, allocator: std.mem.Allocator) void {
        allocator.free(self.node_state);
        allocator.free(self.fwd_side);
        allocator.free(self.rev_side);
        allocator.free(self.degree_fwd);
        allocator.free(self.degree_rev);
    }

    pub fn nodeCount(self: *const CapturedGraphView) usize {
        return self.node_state.len;
    }

    pub fn liveNodeCount(self: *const CapturedGraphView) usize {
        return self.live_node_count;
    }

    pub fn isLiveIndex(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_live_bit) != 0;
    }

    pub fn adjacency(self: *const CapturedGraphView, node_idx: u32) types.NodeAdj {
        const node_state = self.node_state[node_idx];
        const fwd_side = self.fwd_side[node_idx];
        const rev_side = self.rev_side[node_idx];
        return .{
            .first_block_fwd = fwd_side.first_block,
            .block_count_fwd = fwd_side.block_count,
            .group_count_fwd = fwd_side.group_count,
            .first_group_fwd = fwd_side.first_group,
            .first_block_rev = rev_side.first_block,
            .block_count_rev = rev_side.block_count,
            .group_count_rev = rev_side.group_count,
            .first_group_rev = rev_side.first_group,
            .flags = .{
                .needs_repair_fwd = (node_state & state_needs_repair_fwd_bit) != 0,
                .needs_repair_rev = (node_state & state_needs_repair_rev_bit) != 0,
                .removed = (node_state & state_live_bit) == 0,
            },
        };
    }

    pub fn needsRepairFwd(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_needs_repair_fwd_bit) != 0;
    }

    pub fn needsRepairRev(self: *const CapturedGraphView, node_idx: u32) bool {
        return (self.node_state[node_idx] & state_needs_repair_rev_bit) != 0;
    }

    pub fn ensureLiveStart(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!void {
        if (node.index >= self.node_state.len) return error.InvalidNode;
        if (!self.isLiveIndex(node.index)) return error.InvalidNode;
    }

    pub fn outDegree(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!usize {
        try self.ensureLiveStart(node);
        return self.degree_fwd[node.index];
    }

    pub fn inDegree(self: *const CapturedGraphView, node: types.NodeId) types.GraphError!usize {
        try self.ensureLiveStart(node);
        return self.degree_rev[node.index];
    }
};

pub fn captureGraphView(core: *const graph_core.GraphCore, allocator: std.mem.Allocator) !CapturedGraphView {
    const captured = try snapshot_capture.captureStorage(core, allocator);

    return .{
        .core = core,
        .node_state = captured.node_state,
        .fwd_side = captured.fwd_side,
        .rev_side = captured.rev_side,
        .degree_fwd = captured.degree_fwd,
        .degree_rev = captured.degree_rev,
        .live_node_count = captured.live_node_count,
    };
}
