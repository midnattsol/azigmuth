const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_publication_mod = @import("../../storage/node/publication.zig");
const node_adjacency_buffers_mod = @import("../../storage/node/adjacency_buffers.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");

pub const state_live_bit: u8 = 1 << 0;
pub const state_needs_repair_fwd_bit: u8 = 1 << 1;
pub const state_needs_repair_rev_bit: u8 = 1 << 2;

pub const SnapshotSide = types.SideAdj;

pub const CaptureStorage = struct {
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
};

const CapturedNodeData = struct {
    state: u8,
    fwd_side: SnapshotSide,
    rev_side: SnapshotSide,
    degree_fwd: u32,
    degree_rev: u32,
};

pub fn snapshotSide(side: types.SideAdj) SnapshotSide {
    return side;
}

pub fn sideAdjOfSnapshot(snapshot_side: SnapshotSide) types.SideAdj {
    return snapshot_side;
}

const empty_side = types.SideAdj{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };

/// Captures one node from page slices hoisted by the caller. The published
/// side headers are always read — a zero published degree is NOT proof of an
/// empty side header, so eliding them would hide corruption from snapshot
/// validation. The only elision allowed is `published_page == null`: a page
/// that was never allocated cannot hold a non-empty descriptor.
fn captureNodeFromPages(
    publication_cell: *const node_publication_mod.NodePublicationCell,
    buffers_ref: ?*const node_adjacency_buffers_mod.NodeAdjacencyBuffers,
) CapturedNodeData {
    while (true) {
        const before = publication_cell.loadPublicationState();

        var state: u8 = 0;
        if (!before.removed) state |= state_live_bit;
        if (before.needs_repair_fwd) state |= state_needs_repair_fwd_bit;
        if (before.needs_repair_rev) state |= state_needs_repair_rev_bit;

        var fwd_side = empty_side;
        var rev_side = empty_side;
        var degree_fwd: u32 = before.degree_fwd;
        var degree_rev: u32 = before.degree_rev;
        if (buffers_ref) |buffers| {
            fwd_side = buffers.publishedFwdFromState(before);
            rev_side = buffers.publishedRevFromState(before);
            degree_fwd = buffers.publishedFwdDegreeFromState(before);
            degree_rev = buffers.publishedRevDegreeFromState(before);
        }

        const after = publication_cell.loadPublicationState();
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
    const node_state = try allocator.alloc(u8, node_count);
    errdefer allocator.free(node_state);
    const fwd_first_block = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_first_block);
    const fwd_block_count = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_block_count);
    const fwd_segment_count = try allocator.alloc(u16, node_count);
    errdefer allocator.free(fwd_segment_count);
    const fwd_first_segment = try allocator.alloc(u32, node_count);
    errdefer allocator.free(fwd_first_segment);
    const rev_first_block = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_first_block);
    const rev_block_count = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_block_count);
    const rev_segment_count = try allocator.alloc(u16, node_count);
    errdefer allocator.free(rev_segment_count);
    const rev_first_segment = try allocator.alloc(u32, node_count);
    errdefer allocator.free(rev_first_segment);
    const degree_fwd = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_fwd);
    const degree_rev = try allocator.alloc(u32, node_count);
    errdefer allocator.free(degree_rev);

    var live_node_count: usize = 0;

    // Page-hoisted capture: one directory walk per 256-node page instead of
    // several per node. The published-descriptor page may be absent, in which
    // case every node in it provably has empty side headers.
    var node_idx: u32 = 0;
    while (node_idx < node_count) {
        const page_idx = page_ops.pageOf(node_idx, constants.NODES_PER_PAGE);
        const page_end: u32 = @intCast(@min(node_count, (page_idx + 1) * constants.NODES_PER_PAGE));
        const reclamation_page = page_ops.nodePublicationPageAtConst(core, page_idx);
        const published_page = page_ops.nodeAdjacencyBufferPageAtConst(core, page_idx);

        while (node_idx < page_end) : (node_idx += 1) {
            const slot = page_ops.slotOf(node_idx, constants.NODES_PER_PAGE);
            const captured = captureNodeFromPages(
                &reclamation_page[slot],
                if (published_page) |page| &page[slot] else null,
            );
            const node_idx_usize: usize = node_idx;
            node_state[node_idx_usize] = captured.state;
            fwd_first_block[node_idx_usize] = captured.fwd_side.first_block;
            fwd_block_count[node_idx_usize] = captured.fwd_side.block_count;
            fwd_segment_count[node_idx_usize] = captured.fwd_side.segment_count;
            fwd_first_segment[node_idx_usize] = captured.fwd_side.first_segment;
            rev_first_block[node_idx_usize] = captured.rev_side.first_block;
            rev_block_count[node_idx_usize] = captured.rev_side.block_count;
            rev_segment_count[node_idx_usize] = captured.rev_side.segment_count;
            rev_first_segment[node_idx_usize] = captured.rev_side.first_segment;
            degree_fwd[node_idx_usize] = captured.degree_fwd;
            degree_rev[node_idx_usize] = captured.degree_rev;
            if ((captured.state & state_live_bit) != 0) live_node_count += 1;
        }
    }

    return .{
        .node_state = node_state,
        .fwd_first_block = fwd_first_block,
        .fwd_block_count = fwd_block_count,
        .fwd_segment_count = fwd_segment_count,
        .fwd_first_segment = fwd_first_segment,
        .rev_first_block = rev_first_block,
        .rev_block_count = rev_block_count,
        .rev_segment_count = rev_segment_count,
        .rev_first_segment = rev_first_segment,
        .degree_fwd = degree_fwd,
        .degree_rev = degree_rev,
        .live_node_count = live_node_count,
    };
}
