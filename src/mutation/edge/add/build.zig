const std = @import("std");
const tiny_config = @import("../../../core/tiny_config.zig");
const graph_core = @import("../../../core/graph_core.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const node_tiny = @import("../../../storage/node/tiny.zig");
const common = @import("../../common.zig");

pub fn insertForwardEdge(
    graph: *graph_core.GraphCore,
    block_idx: u32,
    destination: types.NodeId,
    relation: u16,
    flags: u16,
    edge_id: u32,
    prop_row: u32,
) !void {
    const forward_block = page_ops.edgeBlockAt(graph, block_idx, .fwd);
    const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, block_idx) else undefined;
    const prop_block = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, block_idx) else undefined;
    const alive = page_ops.blockAliveCount(graph, block_idx, .fwd);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(alive);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (forward_block.destinations[probe] < destination.index) {
            insertion_point = probe + 1;
        } else if (forward_block.destinations[probe] == destination.index) {
            if (!graph.multigraph_enabled) return error.EdgeAlreadyExists;
            if (graph.multigraph_enabled and id_block.ids[probe] < edge_id) {
                insertion_point = probe + 1;
            } else {
                search_end = probe;
            }
        } else {
            search_end = probe;
        }
    }
    var shift: u7 = @intCast(alive);
    while (shift > insertion_point) {
        forward_block.destinations[shift] = forward_block.destinations[shift - 1];
        forward_block.relations[shift] = forward_block.relations[shift - 1];
        forward_block.flags[shift] = forward_block.flags[shift - 1];
        if (graph.multigraph_enabled) id_block.ids[shift] = id_block.ids[shift - 1];
        if (graph.edge_properties_enabled) prop_block.rows[shift] = prop_block.rows[shift - 1];
        shift -= 1;
    }
    forward_block.destinations[insertion_point] = destination.index;
    forward_block.relations[insertion_point] = relation;
    forward_block.flags[insertion_point] = @bitCast((flags));
    if (graph.multigraph_enabled) id_block.ids[insertion_point] = edge_id;
    if (graph.edge_properties_enabled) prop_block.rows[insertion_point] = prop_row;
    page_ops.setBlockAliveCount(graph, block_idx, .fwd, @intCast(alive + 1));
}

pub fn insertReverseEdge(graph: *graph_core.GraphCore, block_idx: u32, source: types.NodeId) void {
    const reverse_block = page_ops.edgeBlockAt(graph, block_idx, .rev);
    const alive = page_ops.blockAliveCount(graph, block_idx, .rev);
    var insertion_point: u7 = 0;
    var search_end: u7 = @intCast(alive);
    while (insertion_point < search_end) {
        const probe: u7 = insertion_point + (search_end - insertion_point) / 2;
        if (reverse_block.sources[probe] < source.index) {
            insertion_point = probe + 1;
        } else {
            search_end = probe;
        }
    }
    var shift: u7 = @intCast(alive);
    while (shift > insertion_point) {
        reverse_block.sources[shift] = reverse_block.sources[shift - 1];
        shift -= 1;
    }
    reverse_block.sources[insertion_point] = source.index;
    page_ops.setBlockAliveCount(graph, block_idx, .rev, @intCast(alive + 1));
}

pub fn canUseTinyFwdSide(graph: *const graph_core.GraphCore, side_adj: types.SideAdj) bool {
    _ = graph;
    return side_adj.block_count == 0 or node_published.NodePublished.isTiny(&side_adj);
}

pub fn canUseTinyRevSide(destination_side: types.SideAdj) bool {
    return destination_side.block_count == 0 or node_published.NodePublished.isTiny(&destination_side);
}

fn cloneTinyFwdIntoNewSlot(graph: *graph_core.GraphCore, side_adj: types.SideAdj, scratch: *common.MutationScratch) !u32 {
    const new_slot_idx = try scratch.allocTinyBlockRaw(graph, .fwd);
    page_ops.tinyBlockAt(graph, new_slot_idx, .fwd).* = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .fwd).*;
    return new_slot_idx;
}

fn cloneTinyRevIntoNewSlot(graph: *graph_core.GraphCore, side_adj: types.SideAdj, scratch: *common.MutationScratch) !u32 {
    const new_slot_idx = try scratch.allocTinyBlockRaw(graph, .rev);
    page_ops.tinyBlockAt(graph, new_slot_idx, .rev).* = page_ops.tinyBlockAtConst(graph, side_adj.first_block, .rev).*;
    return new_slot_idx;
}

pub fn buildForwardTinyOrPromoted(
    graph: *graph_core.GraphCore,
    source_side: types.SideAdj,
    destination: types.NodeId,
    relation: u16,
    raw_flags: u16,
    edge_id: u32,
    prop_row: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    const cap: u16 = if (graph.multigraph_enabled) tiny_config.TINY_FWD_CAP_MULTI else tiny_config.TINY_FWD_CAP_SIMPLE;
    if (source_side.block_count == 0) {
        const slot_idx = try scratch.allocTinyBlockRaw(graph, .fwd);
        const slot = page_ops.tinyBlockAt(graph, slot_idx, .fwd);
        _ = try node_tiny.insertFwd(slot, 0, destination.index, relation, @bitCast(raw_flags), edge_id, prop_row, graph.multigraph_enabled);
        return node_published.NodePublished.makeTiny(slot_idx, 1);
    }

    const count = node_published.NodePublished.tinyCount(&source_side);
    if (count < cap) {
        const slot_idx = try cloneTinyFwdIntoNewSlot(graph, source_side, scratch);
        const slot = page_ops.tinyBlockAt(graph, slot_idx, .fwd);
        const new_count = try node_tiny.insertFwd(slot, count, destination.index, relation, @bitCast(raw_flags), edge_id, prop_row, graph.multigraph_enabled);
        return node_published.NodePublished.makeTiny(slot_idx, new_count);
    }

    const block_idx = try scratch.allocBlock(graph, .fwd);
    const block = page_ops.edgeBlockAt(graph, block_idx, .fwd);
    block.* = std.mem.zeroes(types.EdgeBlockFwd);
    if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, block_idx).* = std.mem.zeroes(types.EdgeBlockFwdIds);
    const slot = page_ops.tinyBlockAtConst(graph, source_side.first_block, .fwd);
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        block.destinations[entry_idx] = entry.destination;
        block.relations[entry_idx] = entry.relation;
        block.flags[entry_idx] = @bitCast(entry.flags);
        if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, block_idx).ids[entry_idx] = entry.edge_id;
        if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, block_idx).rows[entry_idx] = entry.prop_row;
    }
    page_ops.setBlockAliveCount(graph, block_idx, .fwd, @intCast(count));
    try insertForwardEdge(graph, block_idx, destination, relation, raw_flags, edge_id, prop_row);
    return .{ .first_block = block_idx, .block_count = 1, .group_count = 0, .first_group = 0 };
}

pub fn buildReverseTinyOrPromoted(
    graph: *graph_core.GraphCore,
    destination_side: types.SideAdj,
    source: types.NodeId,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    const cap: u16 = tiny_config.TINY_REV_CAP;
    if (destination_side.block_count == 0) {
        const slot_idx = try scratch.allocTinyBlockRaw(graph, .rev);
        const slot = page_ops.tinyBlockAt(graph, slot_idx, .rev);
        _ = node_tiny.insertRev(slot, 0, source.index);
        return node_published.NodePublished.makeTiny(slot_idx, 1);
    }

    const count = node_published.NodePublished.tinyCount(&destination_side);
    if (count < cap) {
        const slot_idx = try cloneTinyRevIntoNewSlot(graph, destination_side, scratch);
        const slot = page_ops.tinyBlockAt(graph, slot_idx, .rev);
        const new_count = node_tiny.insertRev(slot, count, source.index);
        return node_published.NodePublished.makeTiny(slot_idx, new_count);
    }

    const block_idx = try scratch.allocBlock(graph, .rev);
    const block = page_ops.edgeBlockAt(graph, block_idx, .rev);
    block.* = std.mem.zeroes(types.EdgeBlockRev);
    const slot = page_ops.tinyBlockAtConst(graph, destination_side.first_block, .rev);
    for (0..count) |entry_idx| block.sources[entry_idx] = slot.sources[entry_idx];
    page_ops.setBlockAliveCount(graph, block_idx, .rev, @intCast(count));
    insertReverseEdge(graph, block_idx, source);
    return .{ .first_block = block_idx, .block_count = 1, .group_count = 0, .first_group = 0 };
}
