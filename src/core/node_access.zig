const graph_core = @import("graph_core.zig");
const constants = @import("constants.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_published_mod = @import("../storage/node/published.zig");
const types = @import("types.zig");

pub fn nodeAt(graph: *graph_core.GraphCore, node: types.NodeId) *types.NodeBuffer {
    return page_ops.nodeAt(graph, node);
}

pub fn nodeAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) *const types.NodeBuffer {
    return page_ops.nodeAtConst(graph, node);
}

pub fn ensureNodeAt(graph: *graph_core.GraphCore, node: types.NodeId) !*types.NodeBuffer {
    return page_ops.ensureNodeAt(graph, node);
}

fn nodeMetaOf(node_buffer: *const types.NodeBuffer) *const node_meta_mod.NodeMeta {
    return @ptrCast(node_buffer);
}

fn nodeMetaOfMut(node_buffer: *types.NodeBuffer) *node_meta_mod.NodeMeta {
    return @ptrCast(node_buffer);
}

pub fn nodePublishedAt(graph: *graph_core.GraphCore, node: types.NodeId) *node_published_mod.NodePublished {
    return page_ops.nodePublishedAt(graph, node);
}

pub fn nodePublishedAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) *const node_published_mod.NodePublished {
    return page_ops.nodePublishedAtConst(graph, node);
}

pub fn loadPublishedMeta(node_buffer: *const types.NodeBuffer) types.PublishedMeta {
    return nodeMetaOf(node_buffer).loadPublishedMeta();
}

pub fn loadPublishedMetaAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) types.PublishedMeta {
    return page_ops.nodeMetaAtConst(graph, node).loadPublishedMeta();
}

pub fn storePublishedMeta(node_buffer: *types.NodeBuffer, meta: types.PublishedMeta) void {
    nodeMetaOfMut(node_buffer).storePublishedMeta(meta);
}

pub fn cmpxchgPublishedMeta(node_buffer: *types.NodeBuffer, expected: types.PublishedMeta, desired: types.PublishedMeta) ?types.PublishedMeta {
    return nodeMetaOfMut(node_buffer).cmpxchgPublishedMeta(expected, desired);
}

fn composedPublishedAdjFromMeta(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) types.NodeAdj {
    const fwd = publishedFwdFromMeta(graph, node, meta);
    const rev = publishedRevFromMeta(graph, node, meta);
    return .{
        .first_block_fwd = fwd.first_block,
        .block_count_fwd = fwd.block_count,
        .group_count_fwd = fwd.group_count,
        .first_group_fwd = fwd.first_group,
        .first_block_rev = rev.first_block,
        .block_count_rev = rev.block_count,
        .group_count_rev = rev.group_count,
        .first_group_rev = rev.first_group,
        .flags = meta.flags(),
    };
}

pub fn publishedAdjAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) types.NodeAdj {
    while (true) {
        const before = loadPublishedMetaAtConst(graph, node);
        const adjacency = composedPublishedAdjFromMeta(graph, node, before);
        const after = loadPublishedMetaAtConst(graph, node);
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return adjacency;
    }
}

pub fn publishedAdjFromMetaAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) types.NodeAdj {
    return composedPublishedAdjFromMeta(graph, node, meta);
}

pub fn publishedFwdFromMeta(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) types.SideAdj {
    // addNode guarantees the published page exists for every published node,
    // so reads go straight to the canonical pool with no compat branch.
    return page_ops.nodePublishedAtConst(graph, node).publishedFwdFromMeta(meta);
}

pub fn publishedRevFromMeta(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) types.SideAdj {
    return page_ops.nodePublishedAtConst(graph, node).publishedRevFromMeta(meta);
}

pub fn publishedFwdDegreeFromMetaAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) u32 {
    if (!meta.degree_fwd_overflow) return meta.degree_fwd;
    return page_ops.nodePublishedAtConst(graph, node).publishedFwdDegreeFromMeta(meta);
}

pub fn publishedRevDegreeFromMetaAtConst(graph: *const graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) u32 {
    if (!meta.degree_rev_overflow) return meta.degree_rev;
    return page_ops.nodePublishedAtConst(graph, node).publishedRevDegreeFromMeta(meta);
}

pub fn publishedFwdDegreeAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) u32 {
    const node_buffer = nodeAtConst(graph, node);
    while (true) {
        const before = loadPublishedMeta(node_buffer);
        const degree = publishedFwdDegreeFromMetaAtConst(graph, node, before);
        const after = loadPublishedMeta(node_buffer);
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return degree;
    }
}

pub fn publishedRevDegreeAtConst(graph: *const graph_core.GraphCore, node: types.NodeId) u32 {
    const node_buffer = nodeAtConst(graph, node);
    while (true) {
        const before = loadPublishedMeta(node_buffer);
        const degree = publishedRevDegreeFromMetaAtConst(graph, node, before);
        const after = loadPublishedMeta(node_buffer);
        if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) return degree;
    }
}

pub fn stagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) *types.SideAdj {
    return nodeAt(graph, node).stagingFwd(meta);
}

pub fn stagingRev(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) *types.SideAdj {
    return nodeAt(graph, node).stagingRev(meta);
}

pub fn copyPublishedToStagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) void {
    const published = publishedFwdFromMeta(graph, node, meta);
    nodeAt(graph, node).stagingFwd(meta).* = published;
}

pub fn copyPublishedToStagingRev(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) void {
    const published = publishedRevFromMeta(graph, node, meta);
    nodeAt(graph, node).stagingRev(meta).* = published;
}

pub fn writeStagingFwd(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta, side_adj: types.SideAdj) void {
    stagingFwd(graph, node, meta).* = side_adj;
}

pub fn writeStagingRev(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta, side_adj: types.SideAdj) void {
    stagingRev(graph, node, meta).* = side_adj;
}

pub fn syncStagingFwdToPublishedPool(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) void {
    const published = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    published.stagingFwd(meta).* = nodeAt(graph, node).stagingFwd(meta).*;
}

pub fn syncStagingRevToPublishedPool(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta) void {
    const published = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    published.stagingRev(meta).* = nodeAt(graph, node).stagingRev(meta).*;
}

pub fn resetPublishedSides(graph: *graph_core.GraphCore, node: types.NodeId) void {
    const published = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    published.fwd[0] = .{ .first_block = 0, .block_count = 0, .group_count = 0, .first_group = 0 };
    published.fwd[1] = .{ .first_block = 0, .block_count = 0, .group_count = 0, .first_group = 0 };
    published.rev[0] = .{ .first_block = 0, .block_count = 0, .group_count = 0, .first_group = 0 };
    published.rev[1] = .{ .first_block = 0, .block_count = 0, .group_count = 0, .first_group = 0 };
    published.fwd_degrees = [_]u32{0} ** 2;
    published.rev_degrees = [_]u32{0} ** 2;
    published.fwd_sorted = [_]u8{ 1, 1 };
    published.rev_sorted = [_]u8{ 1, 1 };
    const node_buffer = nodeAt(graph, node);
    node_buffer.fwd_buffers[0] = published.fwd[0];
    node_buffer.fwd_buffers[1] = published.fwd[1];
    node_buffer.rev_buffers[0] = published.rev[0];
    node_buffer.rev_buffers[1] = published.rev[1];
}

pub fn setInitialPublishedFwdSide(graph: *graph_core.GraphCore, node: types.NodeId, side_adj: types.SideAdj) void {
    _ = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    // Builder freeze emits globally sorted sides into the initial slot.
    page_ops.nodePublishedAt(graph, node).fwd[0] = side_adj;
    page_ops.nodePublishedAt(graph, node).fwd_sorted[0] = 1;
    nodeAt(graph, node).fwd_buffers[0] = side_adj;
}

pub fn setInitialPublishedRevSide(graph: *graph_core.GraphCore, node: types.NodeId, side_adj: types.SideAdj) void {
    _ = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    page_ops.nodePublishedAt(graph, node).rev[0] = side_adj;
    page_ops.nodePublishedAt(graph, node).rev_sorted[0] = 1;
    nodeAt(graph, node).rev_buffers[0] = side_adj;
}

pub fn setPublishedDegrees(graph: *graph_core.GraphCore, node: types.NodeId, meta: types.PublishedMeta, fwd_degree: u32, rev_degree: u32) void {
    const published = page_ops.ensureNodePublishedAt(graph, node) catch @panic("failed to ensure published page");
    published.fwd_degrees[meta.fwd_index] = fwd_degree;
    published.rev_degrees[meta.rev_index] = rev_degree;
}
