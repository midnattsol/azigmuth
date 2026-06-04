const std = @import("std");
const graph_mod = @import("graph_mod");
const types = graph_mod.types_mod;

pub fn clearPublishedSides(node: *graph_mod.NodeBuffer) void {
    node.fwd_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.fwd_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[0] = std.mem.zeroes(types.SideAdj);
    node.rev_buffers[1] = std.mem.zeroes(types.SideAdj);
    node.storePublishedMeta(.{});
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

pub fn setPublishedState(node: *graph_mod.NodeBuffer, flags: types.NodeFlags, fwd_deg: u22, rev_deg: u22) void {
    var meta = node.loadPublishedMeta();
    meta = meta.withFlags(flags);
    meta.degree_fwd = fwd_deg;
    meta.degree_rev = rev_deg;
    node.storePublishedMeta(meta);
}

pub fn publishedDegrees(node: *graph_mod.NodeBuffer) struct { fwd: u22, rev: u22 } {
    const meta = node.loadPublishedMeta();
    return .{ .fwd = meta.degree_fwd, .rev = meta.degree_rev };
}

pub fn setPublishedFwdDegree(node: *graph_mod.NodeBuffer, deg: u22) void {
    var meta = node.loadPublishedMeta();
    meta.degree_fwd = deg;
    node.storePublishedMeta(meta);
}

pub fn setPublishedRevDegree(node: *graph_mod.NodeBuffer, deg: u22) void {
    var meta = node.loadPublishedMeta();
    meta.degree_rev = deg;
    node.storePublishedMeta(meta);
}

pub fn updatePublishedFlags(node: *graph_mod.NodeBuffer, update: fn (*types.NodeFlags) void) void {
    var flags = node.loadPublishedMeta().flags();
    update(&flags);
    setPublishedFlags(node, flags);
}
