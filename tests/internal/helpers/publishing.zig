const std = @import("std");
const graph_mod = @import("graph_mod");
const node_published = graph_mod.node_published_mod;
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
    return node_published.NodePublished.isTiny(&forwardSideOf(adjacency));
}

pub fn reverseIsTiny(adjacency: types.NodeAdj) bool {
    return node_published.NodePublished.isTiny(&reverseSideOf(adjacency));
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

    var context = Context{ .target = ordinal };
    graph_mod.mutation_common_mod.forEachSlotInSide(&graph.graph, side_adj, side, &context, struct {
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
    return context.found orelse error.IndexOutOfBounds;
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
        const entry = page_ops.tinyFwdAtConst(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG).entries[slot_ref.slot];
        return .{ .destination = entry.destination, .relation = entry.relation, .flags = entry.flags, .edge_id = entry.edge_id };
    }

    const block = page_ops.edgeBlockAtConst(&graph.graph, slot_ref.block_idx, .fwd);
    const edge = block.edges[slot_ref.slot];
    const edge_id = if (graph.graph.multigraph_enabled)
        page_ops.edgeBlockFwdIdsAtConst(&graph.graph, slot_ref.block_idx).ids[slot_ref.slot]
    else
        0;
    return .{ .destination = edge.destination, .relation = edge.relation, .flags = edge.flags, .edge_id = edge_id };
}

pub fn writeForwardDestination(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, destination: u32) !void {
    const slot_ref = try nthSlotRef(graph, forwardSideOf(adjacency), .fwd, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinyFwdAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG).entries[slot_ref.slot].destination = destination;
        return;
    }
    page_ops.edgeBlockAt(&graph.graph, slot_ref.block_idx, .fwd).edges[slot_ref.slot].destination = destination;
}

pub fn writeForwardEdgeId(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, edge_id: u32) !void {
    const slot_ref = try nthSlotRef(graph, forwardSideOf(adjacency), .fwd, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinyFwdAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG).entries[slot_ref.slot].edge_id = edge_id;
        return;
    }
    page_ops.edgeBlockFwdIdsAt(&graph.graph, slot_ref.block_idx).ids[slot_ref.slot] = edge_id;
}

pub fn writeReverseSource(graph: *graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize, source_idx: u32) !void {
    const slot_ref = try nthSlotRef(graph, reverseSideOf(adjacency), .rev, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        page_ops.tinyRevAt(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG).sources[slot_ref.slot] = source_idx;
        return;
    }
    page_ops.edgeBlockAt(&graph.graph, slot_ref.block_idx, .rev).sources[slot_ref.slot] = source_idx;
}

pub fn readReverseSource(graph: *const graph_mod.Graph, adjacency: types.NodeAdj, ordinal: usize) !u32 {
    const slot_ref = try nthSlotRef(graph, reverseSideOf(adjacency), .rev, ordinal);
    if ((slot_ref.block_idx & side_ops.TINY_SLOT_TAG) != 0) {
        return page_ops.tinyRevAtConst(&graph.graph, slot_ref.block_idx & ~side_ops.TINY_SLOT_TAG).sources[slot_ref.slot];
    }
    return page_ops.edgeBlockAtConst(&graph.graph, slot_ref.block_idx, .rev).sources[slot_ref.slot];
}

pub fn appendForwardEntry(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj, entry: ForwardEntry) !void {
    const side_adj = forwardSideOf(adjacency);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const count = node_published.NodePublished.tinyCount(&side_adj);
        page_ops.tinyFwdAt(&graph.graph, side_adj.first_block).entries[count] = .{
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
    const live = @popCount(side.mask);
    side.edges[live] = .{ .destination = entry.destination, .relation = entry.relation, .flags = entry.flags };
    if (graph.graph.multigraph_enabled) {
        page_ops.edgeBlockFwdIdsAt(&graph.graph, side_adj.first_block).ids[live] = entry.edge_id;
    }
    side.mask = graph_mod.constants_mod.denseMask(@intCast(live + 1));
}

pub fn appendReverseSource(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj, source_idx: u32) !void {
    const side_adj = reverseSideOf(adjacency);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        const count = node_published.NodePublished.tinyCount(&side_adj);
        page_ops.tinyRevAt(&graph.graph, side_adj.first_block).sources[count] = source_idx;
        var updated_adj = adjacency;
        updated_adj.block_count_rev = side_adj.block_count + 1;
        const node = try graph.nodeAt(node_id);
        setPublishedAdjSnapshot(node, updated_adj);
        try syncToPublished(graph, node_id.index);
        return;
    }

    const side = page_ops.edgeBlockAt(&graph.graph, side_adj.first_block, .rev);
    const live = @popCount(side.mask);
    side.sources[live] = source_idx;
    side.mask = graph_mod.constants_mod.denseMask(@intCast(live + 1));
}

pub fn truncateReverseByOne(graph: *graph_mod.Graph, node_id: graph_mod.NodeId, adjacency: types.NodeAdj) !void {
    const side_adj = reverseSideOf(adjacency);
    if (node_published.NodePublished.isTiny(&side_adj)) {
        var updated_adj = adjacency;
        updated_adj.block_count_rev = side_adj.block_count - 1;
        const node = try graph.nodeAt(node_id);
        setPublishedAdjSnapshot(node, updated_adj);
        try syncToPublished(graph, node_id.index);
        return;
    }

    const side = page_ops.edgeBlockAt(&graph.graph, side_adj.first_block, .rev);
    const live = @popCount(side.mask);
    side.mask = graph_mod.constants_mod.denseMask(@intCast(live - 1));
}

pub fn ensureForwardBlockLayout(graph: *graph_mod.Graph, node_id: graph_mod.NodeId) !types.NodeAdj {
    const adjacency = try graph.publishedNodeAdj(node_id);
    if (!forwardIsTiny(adjacency)) return adjacency;

    const side_adj = forwardSideOf(adjacency);
    const block_idx = try graph.allocBlockFwd();
    const block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    const slot = page_ops.tinyFwdAtConst(&graph.graph, side_adj.first_block);
    const count = node_published.NodePublished.tinyCount(&side_adj);
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        block.edges[entry_idx] = .{ .destination = entry.destination, .relation = entry.relation, .flags = entry.flags };
        if (graph.graph.multigraph_enabled) {
            page_ops.edgeBlockFwdIdsAt(&graph.graph, block_idx).ids[entry_idx] = entry.edge_id;
        }
    }
    block.mask = graph_mod.constants_mod.denseMask(@intCast(count));

    var updated_adj = adjacency;
    updated_adj.first_block_fwd = block_idx;
    updated_adj.block_count_fwd = 1;
    updated_adj.group_count_fwd = 0;
    updated_adj.first_group_fwd = 0;
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
    const count = node_published.NodePublished.tinyCount(&side_adj);
    for (0..count) |entry_idx| {
        block.sources[entry_idx] = page_ops.tinyRevAtConst(&graph.graph, side_adj.first_block).sources[entry_idx];
    }
    block.mask = graph_mod.constants_mod.denseMask(@intCast(count));

    var updated_adj = adjacency;
    updated_adj.first_block_rev = block_idx;
    updated_adj.block_count_rev = 1;
    updated_adj.group_count_rev = 0;
    updated_adj.first_group_rev = 0;
    const node = try graph.nodeAt(node_id);
    setPublishedAdjSnapshot(node, updated_adj);
    try syncToPublished(graph, node_id.index);
    return updated_adj;
}

pub fn clearPublishedSides(node: *graph_mod.NodeBuffer) void {
    node.fwd_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.fwd_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.storePublishedMeta(.{});
}

pub fn syncToPublished(graph: *graph_mod.Graph, node_idx: u32) !void {
    const node = page_ops.nodeAt(&graph.graph, .{ .index = node_idx });
    const published = try page_ops.ensureNodePublishedAt(&graph.graph, .{ .index = node_idx });
    published.fwd[0] = node.fwd_buffers[0];
    published.fwd[1] = node.fwd_buffers[1];
    published.rev[0] = node.rev_buffers[0];
    published.rev[1] = node.rev_buffers[1];
    page_ops.nodeMetaAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(node.loadPublishedMeta());
}

pub fn syncMetaToPublished(graph: *graph_mod.Graph, node_idx: u32) void {
    const node = page_ops.nodeAt(&graph.graph, .{ .index = node_idx });
    const published = page_ops.ensureNodePublishedAt(&graph.graph, .{ .index = node_idx }) catch @panic("ensureNodePublishedAt failed");
    const meta = node.loadPublishedMeta();
    published.fwd_degrees[meta.fwd_index] = if (meta.degree_fwd_overflow) graph_mod.constants_mod.MAX_DEGREE_PER_SIDE else meta.degree_fwd;
    published.rev_degrees[meta.rev_index] = if (meta.degree_rev_overflow) graph_mod.constants_mod.MAX_DEGREE_PER_SIDE else meta.degree_rev;
    page_ops.nodeMetaAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(node.loadPublishedMeta());
}

pub fn setPublishedFwdDegreeExact(graph: *graph_mod.Graph, node_idx: u32, deg: u32) void {
    const node = page_ops.nodeAt(&graph.graph, .{ .index = node_idx });
    var meta = node.loadPublishedMeta();
    meta = meta.withFwdDegree(deg);
    node.storePublishedMeta(meta);
    const published = page_ops.ensureNodePublishedAt(&graph.graph, .{ .index = node_idx }) catch @panic("ensureNodePublishedAt failed");
    published.fwd_degrees[meta.fwd_index] = deg;
    page_ops.nodeMetaAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(meta);
}

pub fn setPublishedRevDegreeExact(graph: *graph_mod.Graph, node_idx: u32, deg: u32) void {
    const node = page_ops.nodeAt(&graph.graph, .{ .index = node_idx });
    var meta = node.loadPublishedMeta();
    meta = meta.withRevDegree(deg);
    node.storePublishedMeta(meta);
    const published = page_ops.ensureNodePublishedAt(&graph.graph, .{ .index = node_idx }) catch @panic("ensureNodePublishedAt failed");
    published.rev_degrees[meta.rev_index] = deg;
    page_ops.nodeMetaAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(meta);
}

pub fn storePublishedMeta(graph: *graph_mod.Graph, node_idx: u32, meta: types.PublishedMeta) void {
    page_ops.nodeMetaAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(meta);
    page_ops.nodeAt(&graph.graph, .{ .index = node_idx }).storePublishedMeta(meta);
}

pub fn publishedFwdSide(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return &node.fwd_buffers[node.loadPublishedMeta().fwd_index];
}

pub fn publishedRevSide(node: *graph_mod.NodeBuffer) *types.SideAdj {
    return &node.rev_buffers[node.loadPublishedMeta().rev_index];
}

pub fn setPublishedAdjSnapshot(node: *graph_mod.NodeBuffer, adj: types.NodeAdj) void {
    const meta = node.loadPublishedMeta();
    const fwd = publishedFwdSide(node);
    fwd.* = .{
        .first_block = adj.first_block_fwd,
        .block_count = adj.block_count_fwd,
        .group_count = adj.group_count_fwd,
        .first_group = adj.first_group_fwd,
    };
    const rev = publishedRevSide(node);
    rev.* = .{
        .first_block = adj.first_block_rev,
        .block_count = adj.block_count_rev,
        .group_count = adj.group_count_rev,
        .first_group = adj.first_group_rev,
    };
    var new_meta = meta.withFlags(adj.flags);
    new_meta.degree_fwd = meta.degree_fwd;
    new_meta.degree_rev = meta.degree_rev;
    node.storePublishedMeta(new_meta);
}

pub fn setPublishedFlags(node: *graph_mod.NodeBuffer, flags: types.NodeFlags) void {
    const meta = node.loadPublishedMeta();
    node.storePublishedMeta(meta.withFlags(flags));
}

pub fn setPublishedDegrees(node: *graph_mod.NodeBuffer, fwd: u22, rev: u22) void {
    var meta = node.loadPublishedMeta();
    meta.degree_fwd = fwd;
    meta.degree_rev = rev;
    node.storePublishedMeta(meta);
}

pub fn setPublishedState(node: *graph_mod.NodeBuffer, flags: types.NodeFlags, fwd_deg: u32, rev_deg: u32) void {
    var meta = node.loadPublishedMeta();
    meta = meta.withFlags(flags);
    meta = meta.withFwdDegree(fwd_deg).withRevDegree(rev_deg);
    node.storePublishedMeta(meta);
}

pub fn publishedDegrees(node: *graph_mod.NodeBuffer) struct { fwd: u32, rev: u32 } {
    const meta = node.loadPublishedMeta();
    return .{ .fwd = meta.degree_fwd, .rev = meta.degree_rev };
}

pub fn setPublishedFwdDegree(node: *graph_mod.NodeBuffer, deg: u32) void {
    var meta = node.loadPublishedMeta();
    meta = meta.withFwdDegree(deg);
    node.storePublishedMeta(meta);
}

pub fn setPublishedRevDegree(node: *graph_mod.NodeBuffer, deg: u32) void {
    var meta = node.loadPublishedMeta();
    meta = meta.withRevDegree(deg);
    node.storePublishedMeta(meta);
}

pub fn updatePublishedFlags(node: *graph_mod.NodeBuffer, update: fn (*types.NodeFlags) void) void {
    var flags = node.loadPublishedMeta().flags();
    update(&flags);
    setPublishedFlags(node, flags);
}
