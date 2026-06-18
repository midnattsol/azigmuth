const graph_core = @import("graph_core.zig");
const constants = @import("constants.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_publication_mod = @import("../storage/node/publication.zig");
const node_adjacency_buffers_mod = @import("../storage/node/adjacency_buffers.zig");
const types = @import("types.zig");

pub fn nodeAdjacencyBuffersAt(graph: *graph_core.GraphCore, node: types.NodeId) *node_adjacency_buffers_mod.NodeAdjacencyBuffers {
    return page_ops.nodeAdjacencyBuffersAt(graph, node);
}

pub fn nodeAdjacencyBuffersAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) *const node_adjacency_buffers_mod.NodeAdjacencyBuffers {
    return page_ops.nodeAdjacencyBuffersAtConst(graph, node);
}

pub fn loadPublicationStateAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) types.NodePublicationState {
    return page_ops.nodePublicationAtConst(graph, node).loadPublicationState();
}

fn composedPublishedAdjFromState(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) types.NodeAdj {
    const fwd = publishedFwdFromState(graph, node, state);
    const rev = publishedRevFromState(graph, node, state);
    return .{
        .first_block_fwd = fwd.first_block,
        .block_count_fwd = fwd.block_count,
        .segment_count_fwd = fwd.segment_count,
        .first_segment_fwd = fwd.first_segment,
        .first_block_rev = rev.first_block,
        .block_count_rev = rev.block_count,
        .segment_count_rev = rev.segment_count,
        .first_segment_rev = rev.first_segment,
        .flags = state.flags(),
    };
}

pub fn publishedAdjAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) types.NodeAdj {
    while (true) {
        const before = loadPublicationStateAtConst(graph, node);
        const adjacency = composedPublishedAdjFromState(graph, node, before);
        const after = loadPublicationStateAtConst(graph, node);
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return adjacency;
    }
}

pub fn publishedAdjFromStateAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) types.NodeAdj {
    return composedPublishedAdjFromState(graph, node, state);
}

pub fn publishedFwdFromState(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) types.SideAdj {
    // addNode guarantees the published page exists for every published node,
    // so reads go straight to the canonical pool with no compat branch.
    return page_ops.nodeAdjacencyBuffersAtConst(graph, node).publishedFwdFromState(state);
}

pub fn publishedRevFromState(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) types.SideAdj {
    return page_ops.nodeAdjacencyBuffersAtConst(graph, node).publishedRevFromState(state);
}

pub fn publishedFwdDegreeFromStateAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) u32 {
    if (!state.degree_fwd_overflow) return state.degree_fwd;
    return page_ops.nodeAdjacencyBuffersAtConst(graph, node).publishedFwdDegreeFromState(state);
}

pub fn publishedRevDegreeFromStateAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) u32 {
    if (!state.degree_rev_overflow) return state.degree_rev;
    return page_ops.nodeAdjacencyBuffersAtConst(graph, node).publishedRevDegreeFromState(state);
}

pub fn publishedFwdDegreeAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) u32 {
    const node_publication = page_ops.nodePublicationAtConst(graph, node);
    while (true) {
        const before = node_publication.loadPublicationState();
        const degree = publishedFwdDegreeFromStateAtConst(graph, node, before);
        const after = node_publication.loadPublicationState();
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return degree;
    }
}

pub fn publishedRevDegreeAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) u32 {
    const node_publication = page_ops.nodePublicationAtConst(graph, node);
    while (true) {
        const before = node_publication.loadPublicationState();
        const degree = publishedRevDegreeFromStateAtConst(graph, node, before);
        const after = node_publication.loadPublicationState();
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return degree;
    }
}

pub fn stagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) *types.SideAdj {
    return nodeAdjacencyBuffersAt(graph, node).stagingFwd(state);
}

pub fn stagingRev(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) *types.SideAdj {
    return nodeAdjacencyBuffersAt(graph, node).stagingRev(state);
}

pub fn copyPublishedToStagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) void {
    nodeAdjacencyBuffersAt(graph, node).copyPublishedToStagingFwd(state);
}

pub fn copyPublishedToStagingRev(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState) void {
    nodeAdjacencyBuffersAt(graph, node).copyPublishedToStagingRev(state);
}

pub fn writeStagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState, side_adj: types.SideAdj) void {
    stagingFwd(graph, node, state).* = side_adj;
}

pub fn writeStagingRev(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState, side_adj: types.SideAdj) void {
    stagingRev(graph, node, state).* = side_adj;
}

pub fn resetPublishedSides(graph: *graph_core.GraphCore, node: types.NodeId) void {
    const buffers = page_ops.ensureNodeAdjacencyBuffersAt(graph, node) catch @panic("failed to ensure adjacency buffers page");
    buffers.fwd[0] = .{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    buffers.fwd[1] = .{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    buffers.rev[0] = .{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    buffers.rev[1] = .{ .first_block = 0, .block_count = 0, .segment_count = 0, .first_segment = 0 };
    buffers.degrees_fwd = [_]u32{0} ** 2;
    buffers.degrees_rev = [_]u32{0} ** 2;
    buffers.sorted_fwd = [_]u8{ 1, 1 };
    buffers.sorted_rev = [_]u8{ 1, 1 };
}

pub fn setInitialPublishedFwdSide(graph: *graph_core.GraphCore, node: types.NodeId, side_adj: types.SideAdj) void {
    _ = page_ops.ensureNodeAdjacencyBuffersAt(graph, node) catch @panic("failed to ensure published page");
    // Builder freeze emits globally sorted sides into the initial slot.
    page_ops.nodeAdjacencyBuffersAt(graph, node).fwd[0] = side_adj;
    page_ops.nodeAdjacencyBuffersAt(graph, node).sorted_fwd[0] = 1;
}

pub fn setInitialPublishedRevSide(graph: *graph_core.GraphCore, node: types.NodeId, side_adj: types.SideAdj) void {
    _ = page_ops.ensureNodeAdjacencyBuffersAt(graph, node) catch @panic("failed to ensure published page");
    page_ops.nodeAdjacencyBuffersAt(graph, node).rev[0] = side_adj;
    page_ops.nodeAdjacencyBuffersAt(graph, node).sorted_rev[0] = 1;
}

pub fn setPublishedDegrees(graph: *graph_core.GraphCore, node: types.NodeId, state: types.NodePublicationState, fwd_degree: u32, rev_degree: u32) void {
    const buffers = page_ops.ensureNodeAdjacencyBuffersAt(graph, node) catch @panic("failed to ensure adjacency buffers page");
    buffers.degrees_fwd[state.idx_fwd] = fwd_degree;
    buffers.degrees_rev[state.idx_rev] = rev_degree;
}
