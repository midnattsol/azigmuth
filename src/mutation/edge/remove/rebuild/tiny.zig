const std = @import("std");
const graph_core = @import("../../../../core/graph_core.zig");
const types = @import("../../../../core/types.zig");
const page_ops = @import("../../../../storage/page_ops.zig");
const node_published = @import("../../../../storage/node/published.zig");
const adjacency = @import("../../../../adjacency/mod.zig");
const common = @import("common.zig");
const mutation_scratch = @import("../../../scratch.zig");

pub fn rebuildTinyForwardRemoveAll(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_idx: u32,
    scratch: *mutation_scratch.MutationScratch,
) !common.ForwardRemovalResult {
    const count = node_published.NodePublished.tinyCount(published_side);
    const slot = page_ops.tinyFwdAtConst(graph, published_side.first_block);
    var removed: u32 = 0;
    for (0..count) |entry_idx| {
        if (slot.entries[entry_idx].destination == destination_idx) removed += 1;
    }
    if (removed == 0) return .{ .new_side = published_side.*, .removed = 0 };
    if (graph.edge_properties_enabled) {
        for (0..count) |entry_idx| {
            if (slot.entries[entry_idx].destination == destination_idx) {
                try scratch.markRetirePropRow(graph.allocator, slot.entries[entry_idx].prop_row);
            }
        }
    }
    const remaining = count - @as(u16, @intCast(removed));
    if (remaining == 0) return .{ .new_side = std.mem.zeroes(types.SideAdj), .removed = removed };

    const new_slot_idx = try scratch.allocTinySlotRaw(graph, .fwd);
    const new_slot = page_ops.tinyFwdAt(graph, new_slot_idx);
    var write_idx: u16 = 0;
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        if (entry.destination == destination_idx) continue;
        new_slot.entries[write_idx] = entry;
        write_idx += 1;
    }
    return .{ .new_side = node_published.NodePublished.makeTiny(new_slot_idx, remaining), .removed = removed };
}

pub fn rebuildTinyReverseRemoveCount(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    source_idx: u32,
    remove_count: u32,
    scratch: *mutation_scratch.MutationScratch,
) !types.SideAdj {
    const count = node_published.NodePublished.tinyCount(published_side);
    const slot = page_ops.tinyRevAtConst(graph, published_side.first_block);
    var matches: u32 = 0;
    for (0..count) |entry_idx| {
        if (slot.sources[entry_idx] == source_idx) matches += 1;
    }
    if (matches < remove_count) return error.CorruptGraph;
    const remaining = count - @as(u16, @intCast(remove_count));
    if (remaining == 0) return std.mem.zeroes(types.SideAdj);

    const new_slot_idx = try scratch.allocTinySlotRaw(graph, .rev);
    const new_slot = page_ops.tinyRevAt(graph, new_slot_idx);
    var skipped: u32 = 0;
    var write_idx: u16 = 0;
    for (0..count) |entry_idx| {
        const value = slot.sources[entry_idx];
        if (value == source_idx and skipped < remove_count) {
            skipped += 1;
            continue;
        }
        new_slot.sources[write_idx] = value;
        write_idx += 1;
    }
    return node_published.NodePublished.makeTiny(new_slot_idx, remaining);
}

pub fn rebuildTinyForwardRemoveOneById(
    graph: *graph_core.GraphCore,
    published_side: *const types.SideAdj,
    destination_idx: u32,
    edge_id: u32,
    scratch: *mutation_scratch.MutationScratch,
) !?types.SideAdj {
    const count = node_published.NodePublished.tinyCount(published_side);
    const slot = page_ops.tinyFwdAtConst(graph, published_side.first_block);
    const removal_idx = adjacency.findTinyForwardSlotById(graph, published_side.*, destination_idx, edge_id) orelse return null;
    if (graph.edge_properties_enabled) {
        try scratch.markRetirePropRow(graph.allocator, slot.entries[removal_idx].prop_row);
    }
    if (count == 1) return std.mem.zeroes(types.SideAdj);

    const new_slot_idx = try scratch.allocTinySlotRaw(graph, .fwd);
    const new_slot = page_ops.tinyFwdAt(graph, new_slot_idx);
    var write_idx: u16 = 0;
    for (0..count) |entry_idx| {
        if (entry_idx == removal_idx) continue;
        new_slot.entries[write_idx] = slot.entries[entry_idx];
        write_idx += 1;
    }
    return node_published.NodePublished.makeTiny(new_slot_idx, count - 1);
}
