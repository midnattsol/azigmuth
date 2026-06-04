const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const query = @import("../query.zig");

pub fn ensureBitCapacity(bitset: *std.DynamicBitSetUnmanaged, allocator: std.mem.Allocator, node_index: u32) !void {
    const required_len: usize = @as(usize, node_index) + 1;
    if (required_len <= bitset.bit_length) return;
    try bitset.resize(allocator, required_len, false);
}

pub fn neighborIteratorOrNull(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!?query.NeighborIterator {
    return query.neighbors(graph, node) catch |err| switch (err) {
        error.InvalidNode => null,
        else => err,
    };
}

pub fn materializeNeighborsOrEmpty(graph: *const graph_core.GraphCore, node: types.NodeId, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    var iter = try neighborIteratorOrNull(graph, node) orelse return allocator.alloc(types.NodeId, 0);
    return query.materializeConsuming(&iter, allocator);
}
