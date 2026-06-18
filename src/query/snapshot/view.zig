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
    node_state: []u8,
    fwd_first_block: []u32,
    fwd_block_count: []u32,
    fwd_segment_count: []u16,
    fwd_first_segment: []u32,
    rev_first_block: []u32,
    rev_block_count: []u32,
    rev_segment_count: []u16,
    rev_first_segment: []u32,
    degree_fwd: []u32,
    degree_rev: []u32,
    live_node_count: usize,

    pub fn deinit(self: *CapturedGraphView, allocator: std.mem.Allocator) void {
        allocator.free(self.node_state);
        allocator.free(self.fwd_first_block);
        allocator.free(self.fwd_block_count);
        allocator.free(self.fwd_segment_count);
        allocator.free(self.fwd_first_segment);
        allocator.free(self.rev_first_block);
        allocator.free(self.rev_block_count);
        allocator.free(self.rev_segment_count);
        allocator.free(self.rev_first_segment);
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

    pub fn fwdSide(self: *const CapturedGraphView, node_idx: u32) SnapshotSide {
        return .{
            .first_block = self.fwd_first_block[node_idx],
            .block_count = self.fwd_block_count[node_idx],
            .segment_count = self.fwd_segment_count[node_idx],
            .first_segment = self.fwd_first_segment[node_idx],
        };
    }

    pub fn revSide(self: *const CapturedGraphView, node_idx: u32) SnapshotSide {
        return .{
            .first_block = self.rev_first_block[node_idx],
            .block_count = self.rev_block_count[node_idx],
            .segment_count = self.rev_segment_count[node_idx],
            .first_segment = self.rev_first_segment[node_idx],
        };
    }

    pub fn adjacency(self: *const CapturedGraphView, node_idx: u32) types.NodeAdj {
        const node_state = self.node_state[node_idx];
        const fwd_side = self.fwdSide(node_idx);
        const rev_side = self.revSide(node_idx);
        return .{
            .first_block_fwd = fwd_side.first_block,
            .block_count_fwd = fwd_side.block_count,
            .segment_count_fwd = fwd_side.segment_count,
            .first_segment_fwd = fwd_side.first_segment,
            .first_block_rev = rev_side.first_block,
            .block_count_rev = rev_side.block_count,
            .segment_count_rev = rev_side.segment_count,
            .first_segment_rev = rev_side.first_segment,
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
        .fwd_first_block = captured.fwd_first_block,
        .fwd_block_count = captured.fwd_block_count,
        .fwd_segment_count = captured.fwd_segment_count,
        .fwd_first_segment = captured.fwd_first_segment,
        .rev_first_block = captured.rev_first_block,
        .rev_block_count = captured.rev_block_count,
        .rev_segment_count = captured.rev_segment_count,
        .rev_first_segment = captured.rev_first_segment,
        .degree_fwd = captured.degree_fwd,
        .degree_rev = captured.degree_rev,
        .live_node_count = captured.live_node_count,
    };
}
