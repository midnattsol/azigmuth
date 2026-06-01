//! Query layer for neighbor traversal (forward and reverse).

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");
const rcu = @import("rcu.zig");

pub const Direction = enum { fwd, rev };

pub const NeighborIterator = struct {
    core: *const graph_core.GraphCore,
    direction: Direction,
    node_adj_snapshot: types.NodeAdj,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_mask: u64,
    current_block_for_mask: u32,
    /// Cached from loadNextNonEmptyMask so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,

    reader_active: bool,
    reader_token: rcu.ReaderToken,

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

            switch (self.direction) {
                .fwd => {
                    const block = page_ops.edgeBlockAtConst(self.core, block_index, .fwd);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_fwd_block = block;
                    self.cached_rev_block = null;
                },
                .rev => {
                    const block = page_ops.edgeBlockAtConst(self.core, block_index, .rev);
                    if (block.mask == 0) continue;
                    self.current_mask = block.mask;
                    self.cached_rev_block = block;
                    self.cached_fwd_block = null;
                },
            }
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
        return switch (self.direction) {
            .fwd => blk: {
                break :blk types.NodeId{ .index = self.cached_fwd_block.?.edges[bit_index].destination };
            },
            .rev => blk: {
                break :blk types.NodeId{ .index = self.cached_rev_block.?.sources[bit_index] };
            },
        };
    }

    pub fn deinit(self: *NeighborIterator) void {
        if (!self.reader_active) return;
        rcu.readerExit(@constCast(self.core), self.reader_token);
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

fn initNeighborIterator(graph: *const graph_core.GraphCore, node: types.NodeId, direction: Direction) types.GraphError!NeighborIterator {
    if (node.index >= graph.node_count) return error.InvalidNode;

    const reader_token = rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const node_adj_snapshot = node_buffer.publishedAdj();

    const initial = buildIteratorState(direction, node_adj_snapshot);

    var iterator = NeighborIterator{
        .core = graph,
        .direction = direction,
        .node_adj_snapshot = node_adj_snapshot,
        .contiguous_mode = initial.contiguous_mode,
        .current_block_index = initial.current_block_index,
        .blocks_remaining = initial.blocks_remaining,
        .current_group_index = initial.current_group_index,
        .current_mask = 0,
        .current_block_for_mask = 0,
        .reader_active = true,
        .reader_token = reader_token,
    };

    if (!iterator.contiguous_mode and iterator.current_group_index != constants.END_OF_CHAIN) {
        const first_group = page_ops.groupAtConst(graph, iterator.current_group_index);
        iterator.current_block_index = first_group.start;
        iterator.blocks_remaining = first_group.count;
    }

    return iterator;
}

pub fn neighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .fwd);
}

pub fn inNeighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .rev);
}

fn sumPopCount(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, comptime side: Direction) usize {
    const block_count: u32 = switch (side) {
        .fwd => node_adj.block_count_fwd,
        .rev => node_adj.block_count_rev,
    };
    const group_count: u32 = switch (side) {
        .fwd => node_adj.group_count_fwd,
        .rev => node_adj.group_count_rev,
    };

    if (block_count == 0) return 0;

    var total: usize = 0;

    if (group_count == 0) {
        const start: u32 = switch (side) {
            .fwd => node_adj.first_block_fwd,
            .rev => node_adj.first_block_rev,
        };
        for (start..start + block_count) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), switch (side) {
                .fwd => .fwd,
                .rev => .rev,
            });
            total += @popCount(block.mask);
        }
        return total;
    }

    var group_index: u32 = switch (side) {
        .fwd => node_adj.first_group_fwd,
        .rev => node_adj.first_group_rev,
    };
    while (group_index != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_index);
        for (group.start..group.start + group.count) |block_index| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_index), switch (side) {
                .fwd => .fwd,
                .rev => .rev,
            });
            total += @popCount(block.mask);
        }
        group_index = group.next;
    }

    return total;
}

pub fn outDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (node.index >= graph.node_count) return error.InvalidNode;
    const reader_token = rcu.readerEnter(@constCast(graph));
    defer rcu.readerExit(@constCast(graph), reader_token);
    const adjacency = page_ops.nodeAtConst(graph, node).publishedAdj();
    return sumPopCount(graph, adjacency, .fwd);
}

pub fn inDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (node.index >= graph.node_count) return error.InvalidNode;
    const reader_token = rcu.readerEnter(@constCast(graph));
    defer rcu.readerExit(@constCast(graph), reader_token);
    const adjacency = page_ops.nodeAtConst(graph, node).publishedAdj();
    return sumPopCount(graph, adjacency, .rev);
}
