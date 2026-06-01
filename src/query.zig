//! Query layer for neighbor traversal (forward and reverse).

const std = @import("std");
const constants = @import("constants.zig");
const graph = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");

pub const Direction = enum { fwd, rev };

pub const NeighborIterator = struct {
    core: *const graph.GraphCore,
    direction: Direction,
    node_adj_snapshot: types.NodeAdj,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    current_block_for_mask: u32,

    reader_active: bool,

    fn currentBlockMask(self: *const NeighborIterator, block_index: u32) u64 {
        return switch (self.direction) {
            .fwd => page_ops.edgeBlockAtConst(self.core, block_index, .fwd).mask,
            .rev => page_ops.edgeBlockAtConst(self.core, block_index, .rev).mask,
        };
    }

    fn currentBlockNeighbor(self: *const NeighborIterator, block_index: u32, bit_index: u6) types.NodeId {
        return switch (self.direction) {
            .fwd => blk: {
                const block = page_ops.edgeBlockAtConst(self.core, block_index, .fwd);
                break :blk types.NodeId{ .index = block.edges[bit_index].dest };
            },
            .rev => blk: {
                const block = page_ops.edgeBlockAtConst(self.core, block_index, .rev);
                break :blk types.NodeId{ .index = block.sources[bit_index] };
            },
        };
    }

    fn advanceToNextGroup(self: *NeighborIterator) bool {
        if (self.contiguous_mode) return false;
        if (self.current_group_index == constants.END_OF_CHAIN) return false;

        const current = page_ops.groupAtConst(self.core, self.current_group_index);
        if (current.next == constants.END_OF_CHAIN) {
            self.current_group_index = constants.END_OF_CHAIN;
            return false;
        }

        self.current_group_index = current.next;
        const next_group = page_ops.groupAtConst(self.core, self.current_group_index);
        self.current_block_index = next_group.start;
        self.blocks_remaining = next_group.count;
        return true;
    }

    fn loadNextNonEmptyMask(self: *NeighborIterator) bool {
        while (true) {
            if (self.blocks_remaining == 0) {
                if (!self.advanceToNextGroup()) return false;
            }

            const block_index = self.current_block_index;
            self.current_block_index += 1;
            self.blocks_remaining -= 1;

            const mask = self.currentBlockMask(block_index);
            if (mask == 0) continue;

            self.current_mask = mask;
            self.current_block_for_mask = block_index;
            return true;
        }
    }

    pub fn next(self: *NeighborIterator) ?types.NodeId {
        while (self.current_mask == 0) {
            if (!self.loadNextNonEmptyMask()) return null;
        }

        const bit_index: u6 = @intCast(@ctz(self.current_mask));
        self.current_mask &= self.current_mask - 1;
        return self.currentBlockNeighbor(self.current_block_for_mask, bit_index);
    }

    pub fn deinit(self: *NeighborIterator) void {
        if (!self.reader_active) return;
        _ = @constCast(self.core).active_readers.fetchSub(1, .monotonic);
        self.reader_active = false;
    }

    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) ![]types.NodeId {
        defer self.deinit();
        var out: std.ArrayList(types.NodeId) = .empty;
        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn buildIteratorState(direction: Direction, node_adj: types.NodeAdj) struct {
    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,
} {
    const block_count: u32 = if (direction == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    const group_count: u32 = if (direction == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;

    if (block_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = 0,
            .blocks_remaining = 0,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    if (group_count == 0) {
        return .{
            .contiguous_mode = true,
            .current_block_index = if (direction == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev,
            .blocks_remaining = block_count,
            .current_group_index = constants.END_OF_CHAIN,
        };
    }

    return .{
        .contiguous_mode = false,
        .current_block_index = 0,
        .blocks_remaining = 0,
        .current_group_index = if (direction == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev,
    };
}

fn initNeighborIterator(core: *const graph.GraphCore, node: types.NodeId, direction: Direction) types.GraphError!NeighborIterator {
    if (node.index >= core.node_count) return error.InvalidNode;

    _ = @constCast(core).active_readers.fetchAdd(1, .monotonic);
    errdefer _ = @constCast(core).active_readers.fetchSub(1, .monotonic);

    const node_buffer = page_ops.nodeAtConst(core, node);
    const node_adj_snapshot = node_buffer.publishedAdj();

    const initial = buildIteratorState(direction, node_adj_snapshot);

    var iterator = NeighborIterator{
        .core = core,
        .direction = direction,
        .node_adj_snapshot = node_adj_snapshot,
        .contiguous_mode = initial.contiguous_mode,
        .current_block_index = initial.current_block_index,
        .blocks_remaining = initial.blocks_remaining,
        .current_group_index = initial.current_group_index,
        .current_mask = 0,
        .current_block_for_mask = 0,
        .reader_active = true,
    };

    if (!iterator.contiguous_mode and iterator.current_group_index != constants.END_OF_CHAIN) {
        const first_group = page_ops.groupAtConst(core, iterator.current_group_index);
        iterator.current_block_index = first_group.start;
        iterator.blocks_remaining = first_group.count;
    }

    return iterator;
}

pub fn neighbors(core: *const graph.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(core, node, .fwd);
}

pub fn inNeighbors(core: *const graph.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(core, node, .rev);
}

pub fn outDegree(core: *const graph.GraphCore, node: types.NodeId) types.GraphError!usize {
    var iterator = try neighbors(core, node);
    defer iterator.deinit();
    var degree: usize = 0;
    while (iterator.next() != null) degree += 1;
    return degree;
}

pub fn inDegree(core: *const graph.GraphCore, node: types.NodeId) types.GraphError!usize {
    var iterator = try inNeighbors(core, node);
    defer iterator.deinit();
    var degree: usize = 0;
    while (iterator.next() != null) degree += 1;
    return degree;
}
