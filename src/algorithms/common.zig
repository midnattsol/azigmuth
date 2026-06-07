const std = @import("std");
const read_session = @import("read_session.zig");

pub fn ensureBitCapacity(bitset: *std.DynamicBitSetUnmanaged, allocator: std.mem.Allocator, node_index: u32) !void {
    const required_len: usize = @as(usize, node_index) + 1;
    if (required_len <= bitset.bit_length) return;
    try bitset.resize(allocator, required_len, false);
}

pub const ReadSession = read_session.ReadSession;
pub const NeighborsCursor = read_session.NeighborsCursor;
