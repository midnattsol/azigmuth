const std = @import("std");
const graph_mod = @import("graph_mod");
const node_adjacency_buffers = graph_mod.node_adjacency_buffers_mod;
const side_ops = graph_mod.side_ops_mod;
const types = graph_mod.types_mod;
const page_ops = graph_mod.page_ops_mod;

pub const ForwardEntry = struct {
    destination: u32,
    relation: u16,
    flags: types.EdgeFlags,
    edge_id: u32,
};

pub fn forwardSideOf(adjacency: types.NodeAdj) types.SideAdj {
    return graph_mod.adjacency_mod.sideAdjOfNode(adjacency, .fwd);
}

pub fn reverseSideOf(adjacency: types.NodeAdj) types.SideAdj {
    return graph_mod.adjacency_mod.sideAdjOfNode(adjacency, .rev);
}

pub fn forwardIsTiny(adjacency: types.NodeAdj) bool {
    return node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&forwardSideOf(adjacency));
}

pub fn reverseIsTiny(adjacency: types.NodeAdj) bool {
    return node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&reverseSideOf(adjacency));
}

fn nthSlotRef(
    graph: *const graph_mod.Graph,
    side_adj: types.SideAdj,
    comptime side: graph_mod.adjacency_mod.AdjSide,
    ordinal: usize,
) !side_ops.AdjSlot {
    const Context = struct {
        target: usize,
        current: usize = 0,
        found: ?side_ops.AdjSlot = null,
    };

    var slot_ctx = Context{ .target = ordinal };
    graph_mod.mutation_common_mod.forEachSlotInSide(&graph.graph, side_adj, side, &slot_ctx, struct {
        fn callback(_: *const graph_mod.GraphCore, ctx: *Context, block_idx: u32, slot: u7) !void {
            if (ctx.current == ctx.target) {
                ctx.found = .{ .block_idx = block_idx, .slot = slot };
                return error.Found;
            }
            ctx.current += 1;
        }
    }.callback) catch |err| {
        if (err != error.Found) return err;
    };
    return slot_ctx.found orelse error.IndexOutOfBounds;
}

pub fn forwardLiveCount(graph: *const graph_mod.Graph, adjacency: types.NodeAdj) !usize {
    return graph_mod.mutation_common_mod.countLiveInSide(&graph.graph, forwardSideOf(adjacency), .fwd);
}

pub fn reverseLiveCount(graph: *const graph_mod.Graph, adjacency: types.NodeAdj) !usize {
    return graph_mod.mutation_common_mod.countLiveInSide(&graph.graph, reverseSideOf(adjacency), .rev);
}

pub fn readForwardEntry(graph: *const graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize) !ForwardEntry {
    const slot_ref = try nthSlotRef(graph, forwardSideOf(adjacency), .fwd, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        const entry = page_ops.tinySlotAtConst(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG, .fwd).entries[slot_ref.slot];
        return .{ .destination = entry.destination, .relation = entry.relation, .flags = entry.flags, .edge_id = entry.edge_id };
    }

    const block = page_ops.edgeBlockAtConst(&graph.graph, slot_ref.block_idx, .fwd);
    const edge_id = if (graph.graph.multigraph_enabled)
        page_ops.edgeBlockFwdIdsAtConst(&graph.graph, slot_ref.block_idx).ids[slot_ref.slot]
    else
        0;
    return .{ .destination = block.destinations[slot_ref.slot], .relation = block.relations[slot_ref.slot], .flags = @bitCast(block.flags[slot_ref.slot]), .edge_id = edge_id };
}

pub fn writeForwardDestination(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, destination: u32) !void {
    const slot_ref = try nthSlotRef(graph, forwardSideOf(adjacency), .fwd, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinySlotAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG, .fwd).entries[slot_ref.slot].destination = destination;
        return;
    }
    page_ops.edgeBlockAt(&graph.graph, slot_ref.block_idx, .fwd).destinations[slot_ref.slot] = destination;
}

pub fn writeForwardEdgeId(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, edge_id: u32) !void {
    const slot_ref = try nthSlotRef(graph, forwardSideOf(adjacency), .fwd, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinySlotAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG, .fwd).entries[slot_ref.slot].edge_id = edge_id;
        return;
    }
    page_ops.edgeBlockFwdIdsAt(&graph.graph, slot_ref.block_idx).ids[slot_ref.slot] = edge_id;
}

pub fn writeReverseSource(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, source_idx: u32) !void {
    const slot_ref = try nthSlotRef(graph, reverseSideOf(adjacency), .rev, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinySlotAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG, .rev).sources[slot_ref.slot] = source_idx;
        return;
    }
    page_ops.edgeBlockAt(&graph.graph, slot_ref.block_idx, .rev).sources[slot_ref.slot] = source_idx;
}

pub fn readReverseSource(graph: *const graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize) !u32 {
    const slot_ref = try nthSlotRef(graph, reverseSideOf(adjacency), .rev, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        return page_ops.tinySlotAtConst(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG, .rev).sources[slot_ref.slot];
    }
    return page_ops.edgeBlockAtConst(&graph.graph, slot_ref.block_idx, .rev).sources[slot_ref.slot];
}

pub fn appendForwardEntry(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj, entry: ForwardEntry) !void {
    const side_adj = forwardSideOf(adjacency);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
        page_ops.tinySlotAt(&graph.graph, side_adj.first_block, .fwd).entries[count] = .{
            .destination = entry.destination,
            .relation = entry.relation,
            .flags = entry.flags,
            .edge_id = entry.edge_id,
        };
        var updated_adj = adjacency;
        updated_adj.block_count_fwd = side_adj.block_count + 1;
        const node = try graph.nodeAt(node_id);
        setPublishedAdjSnapshot(node, updated_adj);
        try syncToPublished(graph, node_id.index);
        return;
    }

    const side = page_ops.edgeBlockAt(&graph.graph, side_adj.first_block, .fwd);
    const alive = page_ops.blockAliveCount(&graph.graph, side_adj.first_block, .fwd);
    side.destinations[alive] = entry.destination;
    side.relations[alive] = entry.relation;
    side.flags[alive] = @bitCast(entry.flags);
    if (graph.graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(&graph.graph, side_adj.first_block).ids[alive] = entry.edge_id;
    }
    page_ops.setBlockAliveCount(&graph.graph, side_adj.first_block, .fwd, @intCast(alive + 1));
}

pub fn appendReverseSource(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj, source_idx: u32) !void {
    const side_adj = reverseSideOf(adjacency);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
        page_ops.tinySlotAt(&graph.graph, side_adj.first_block, .rev).sources[count] = source_idx;
        var updated_adj = adjacency;
        updated_adj.block_count_rev = side_adj.block_count + 1;
        const node = try graph.nodeAt(node_id);
        setPublishedAdjSnapshot(node, updated_adj);
        try syncToPublished(graph, node_id.index);
        return;
    }

    const alive = page_ops.blockAliveCount(&graph.graph, side_adj.first_block, .rev);
    page_ops.edgeBlockAt(&graph.graph, side_adj.first_block, .rev).sources[alive] = source_idx;
    page_ops.setBlockAliveCount(&graph.graph, side_adj.first_block, .rev, @intCast(alive + 1));
}

pub fn truncateReverseByOne(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj) !void {
    const side_adj = reverseSideOf(adjacency);
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        var updated_adj = adjacency;
        updated_adj.block_count_rev = side_adj.block_count - 1;
        const node = try graph.nodeAt(node_id);
        setPublishedAdjSnapshot(node, updated_adj);
        try syncToPublished(graph, node_id.index);
        return;
    }

    const alive = page_ops.blockAliveCount(&graph.graph, side_adj.first_block, .rev);
    page_ops.setBlockAliveCount(&graph.graph, side_adj.first_block, .rev, @intCast(alive - 1));
}

pub fn ensureForwardBlockLayout(graph: *graph_mod.Graph, node_id: graph_mod.NodeId) !types.NodeAdj {
    const adjacency = try graph.publishedNodeAdj(node_id);
    if (!forwardIsTiny(adjacency)) return adjacency;

    const side_adj = forwardSideOf(adjacency);
    const block_idx = try graph.allocBlockFwd();
    const block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    const slot = page_ops.tinySlotAtConst(&graph.graph, side_adj.first_block, .fwd);
    const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        block.destinations[entry_idx] = entry.destination;
        block.relations[entry_idx] = entry.relation;
        block.flags[entry_idx] = @bitCast(entry.flags);
        if (graph.graph.multigraph_enabled) {
            page_ops.edgeBlockFwdIdsAt(&graph.graph, block_idx).ids[entry_idx] = entry.edge_id;
        }
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .fwd, @intCast(count));

    var updated_adj = adjacency;
    updated_adj.first_block_fwd = block_idx;
    updated_adj.block_count_fwd = 1;
    updated_adj.segment_count_fwd = 0;
    updated_adj.first_segment_fwd = 0;
    const node = try graph.nodeAt(node_id);
    setPublishedAdjSnapshot(node, updated_adj);
    try syncToPublished(graph, node_id.index);
    return updated_adj;
}

pub fn ensureReverseBlockLayout(graph: *graph_mod.Graph, node_id: graph_mod.NodeId) !types.NodeAdj {
    const adjacency = try graph.publishedNodeAdj(node_id);
    if (!reverseIsTiny(adjacency)) return adjacency;

    const side_adj = reverseSideOf(adjacency);
    const block_idx = try graph.allocBlockRev();
    const block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    const count = node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&side_adj);
    for (0..count) |entry_idx| {
        block.sources[entry_idx] = page_ops.tinySlotAtConst(&graph.graph, side_adj.first_block, .rev).sources[entry_idx];
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .rev, @intCast(count));

    var updated_adj = adjacency;
    updated_adj.first_block_rev = block_idx;
    updated_adj.block_count_rev = 1;
    updated_adj.segment_count_rev = 0;
    updated_adj.first_segment_rev = 0;
    const node = try graph.nodeAt(node_id);
    setPublishedAdjSnapshot(node, updated_adj);
    try syncToPublished(graph, node_id.index);
    return updated_adj;
}

const NodeRef = graph_mod.Graph.NodeRef;

fn publicationCellOf(ref: NodeRef) *graph_mod.node_publication_mod.NodePublicationCell {
    return page_ops.nodePublicationAt(ref.core, ref.node);
}

fn adjacencyBuffersOf(ref: NodeRef) *node_adjacency_buffers.NodeAdjacencyBuffers {
    return page_ops.ensureNodeAdjacencyBuffersAt(ref.core, ref.node) catch @panic("ensureNodeAdjacencyBuffersAt failed");
}

pub fn clearPublishedSides(ref: NodeRef) void {
    const buffers = adjacencyBuffersOf(ref);
    buffers.fwd[0] = std.mem.zeroes(types.SideAdj);
    buffers.fwd[1] = std.mem.zeroes(types.SideAdj);
    buffers.rev[0] = std.mem.zeroes(types.SideAdj);
    buffers.rev[1] = std.mem.zeroes(types.SideAdj);
    buffers.degrees_fwd = [_]u32{0} ** 2;
    buffers.degrees_rev = [_]u32{0} ** 2;
    publicationCellOf(ref).storePublicationState(.{});
}

/// The published pool is canonical: nothing to sync. Kept so white-box tests
/// that publish through this helper keep their call shape.
pub fn syncToPublished(graph: *graph_mod.Graph, node_idx: u32) !void {
    _ = graph;
    _ = node_idx;
}

pub fn syncPublicationStateToPublished(graph: *graph_mod.Graph, node_idx: u32) void {
    _ = graph;
    _ = node_idx;
}

pub fn setPublishedFwdDegreeExact(graph: *graph_mod.Graph, node_idx: u32, deg: u32) void {
    const node_publication = page_ops.nodePublicationAt(&graph.graph, .{ .index = node_idx });
    var state = node_publication.loadPublicationState();
    state = state.withFwdDegree(deg);
    const buffers = page_ops.ensureNodeAdjacencyBuffersAt(&graph.graph, .{ .index = node_idx }) catch @panic("ensureNodeAdjacencyBuffersAt failed");
    buffers.degrees_fwd[state.idx_fwd] = deg;
    node_publication.storePublicationState(state);
}

pub fn setPublishedRevDegreeExact(graph: *graph_mod.Graph, node_idx: u32, deg: u32) void {
    const node_publication = page_ops.nodePublicationAt(&graph.graph, .{ .index = node_idx });
    var state = node_publication.loadPublicationState();
    state = state.withRevDegree(deg);
    const buffers = page_ops.ensureNodeAdjacencyBuffersAt(&graph.graph, .{ .index = node_idx }) catch @panic("ensureNodeAdjacencyBuffersAt failed");
    buffers.degrees_rev[state.idx_rev] = deg;
    node_publication.storePublicationState(state);
}

pub fn storePublicationState(graph: *graph_mod.Graph, node_idx: u32, state: types.NodePublicationState) void {
    page_ops.nodePublicationAt(&graph.graph, .{ .index = node_idx }).storePublicationState(state);
}

pub fn publishedFwdSide(ref: NodeRef) *types.SideAdj {
    const buffers = adjacencyBuffersOf(ref);
    return &buffers.fwd[publicationCellOf(ref).loadPublicationState().idx_fwd];
}

pub fn publishedRevSide(ref: NodeRef) *types.SideAdj {
    const buffers = adjacencyBuffersOf(ref);
    return &buffers.rev[publicationCellOf(ref).loadPublicationState().idx_rev];
}

pub fn setPublishedAdjSnapshot(ref: NodeRef, adj: types.NodeAdj) void {
    const state = publicationCellOf(ref).loadPublicationState();
    publishedFwdSide(ref).* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .segment_count = adj.segment_count_fwd,
        .first_segment = adj.first_segment_fwd,
    };
    publishedRevSide(ref).* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .segment_count = adj.segment_count_rev,
        .first_segment = adj.first_segment_rev,
    };
    var new_state = state.withFlags(adj.flags);
    new_state.degree_fwd = state.degree_fwd;
    new_state.degree_rev = state.degree_rev;
    publicationCellOf(ref).storePublicationState(new_state);
}

pub fn setPublishedFlags(ref: NodeRef, flags: types.NodeFlags) void {
    const state = publicationCellOf(ref).loadPublicationState();
    publicationCellOf(ref).storePublicationState(state.withFlags(flags));
}

pub fn setPublishedDegrees(ref: NodeRef, fwd: u22, rev: u22) void {
    var state = publicationCellOf(ref).loadPublicationState();
    state.degree_fwd = fwd;
    state.degree_rev = rev;
    publicationCellOf(ref).storePublicationState(state);
}

pub fn setPublishedState(ref: NodeRef, flags: types.NodeFlags, fwd_deg: u32, rev_deg: u32) void {
    var state = publicationCellOf(ref).loadPublicationState();
    state = state.withFlags(flags);
    state = state.withFwdDegree(fwd_deg).withRevDegree(rev_deg);
    publicationCellOf(ref).storePublicationState(state);
}

pub fn publishedDegrees(ref: NodeRef) struct { fwd: u32, rev: u32 } {
    const state = publicationCellOf(ref).loadPublicationState();
    return .{ .fwd = state.degree_fwd, .rev = state.degree_rev };
}

pub fn setPublishedFwdDegree(ref: NodeRef, deg: u32) void {
    var state = publicationCellOf(ref).loadPublicationState();
    state = state.withFwdDegree(deg);
    publicationCellOf(ref).storePublicationState(state);
}

pub fn setPublishedRevDegree(ref: NodeRef, deg: u32) void {
    var state = publicationCellOf(ref).loadPublicationState();
    state = state.withRevDegree(deg);
    publicationCellOf(ref).storePublicationState(state);
}

pub fn updatePublishedFlags(ref: NodeRef, update: fn (*types.NodeFlags) void) void {
    var flags = publicationCellOf(ref).loadPublicationState().flags();
    update(&flags);
    setPublishedFlags(ref, flags);
}
