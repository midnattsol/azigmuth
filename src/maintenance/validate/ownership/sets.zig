const common = @import("../common.zig");
const stacks = @import("../stacks.zig");
const std = @import("std");
const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");

pub fn buildFreeBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: common.Side,
) !std.DynamicBitSetUnmanaged {
    const limit = common.allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.blockStackHeadIndex(graph, .free, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

pub fn buildRetiredBlockSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    comptime side: common.Side,
) !std.DynamicBitSetUnmanaged {
    const limit = common.allocatedBlockCount(graph, side);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var current = stacks.blockStackHeadIndex(graph, .retired, side);
    var visited: u32 = 0;
    while (current != constants.END_OF_CHAIN) : (visited += 1) {
        if (visited >= limit) break;
        if (current < limit) set.set(current);
        current = stacks.blockMetaNextFast(graph, current, side) catch break;
    }
    return set;
}

pub fn buildFreeGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        var current = stacks.groupSpanStackHeadIndexFast(graph, .free, span_count);
        var visited: u32 = 0;
        while (current != constants.END_OF_CHAIN) : (visited += 1) {
            if (visited >= limit) break;
            for (current..@min(current + span_count, limit)) |group_idx_usize| {
                set.set(@intCast(group_idx_usize));
            }
            current = stacks.groupMetaNextFast(graph, current) catch break;
        }
    }
    return set;
}

pub fn buildRetiredGroupSet(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
) !std.DynamicBitSetUnmanaged {
    const limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, limit);
    var span_count: u16 = 1;
    while (span_count <= constants.MAX_GROUPS_PER_NODE) : (span_count += 1) {
        var current = stacks.groupSpanStackHeadIndexFast(graph, .retired, span_count);
        var visited: u32 = 0;
        while (current != constants.END_OF_CHAIN) : (visited += 1) {
            if (visited >= limit) break;
            for (current..@min(current + span_count, limit)) |group_idx_usize| {
                set.set(@intCast(group_idx_usize));
            }
            current = stacks.groupMetaNextFast(graph, current) catch break;
        }
    }
    return set;
}

pub fn markOwnedBlock(
    owned_blocks: *std.DynamicBitSetUnmanaged,
    block_index: u32,
) bool {
    const bit_index: usize = @intCast(block_index);
    if (owned_blocks.isSet(bit_index)) return false;
    owned_blocks.set(bit_index);
    return true;
}
