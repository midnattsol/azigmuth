//! Canonical neighbor iterator type shared by the public API and internal query
//! helpers. Returned by value; creation does not allocate. Iterators are
//! logically single-owner values: copying and using multiple copies is
//! unsupported.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const iterator_common = @import("iterator_common.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const rcu = @import("rcu.zig");
const node_validity = @import("core/node_validity.zig");

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
    /// Cached from loadNextNonEmptyMask so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,
    cached_node_page_index: u32 = constants.END_OF_CHAIN,
    cached_node_page: ?[]const types.NodeBuffer = null,

    degree_snapshot: usize,

    reader_active: bool,
    reader_token: rcu.ReaderToken,

    /// Safeguard against corrupt cyclic group chains: stop advancing
    /// after visiting more groups than the adjacency snapshot declares.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *NeighborIterator) bool {
        return iterator_common.advanceToNextGroup(self, self.core);
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
            return true;
        }
    }

    fn candidateRemoved(self: *NeighborIterator, candidate_index: u32) bool {
        return iterator_common.candidateRemoved(self, self.core, candidate_index);
    }

    pub fn next(self: *NeighborIterator) ?types.NodeId {
        if (!self.reader_active) return null;
        if (!rcu.readerTokenActive(self.reader_token)) {
            self.reader_active = false;
            return null;
        }
        while (true) {
            while (self.current_mask == 0) {
                if (!self.loadNextNonEmptyMask()) return null;
            }

            const bit_index: u6 = @intCast(@ctz(self.current_mask));
            self.current_mask &= self.current_mask - 1;
            const candidate = switch (self.direction) {
                .fwd => blk: {
                    break :blk types.NodeId{ .index = self.cached_fwd_block.?.edges[bit_index].destination };
                },
                .rev => blk: {
                    break :blk types.NodeId{ .index = self.cached_rev_block.?.sources[bit_index] };
                },
            };
            if (self.candidateRemoved(candidate.index)) continue;
            return candidate;
        }
    }

    pub fn deinit(self: *NeighborIterator) void {
        iterator_common.deinitReader(self, self.core);
    }

    /// Drains remaining items into a caller-owned slice. Allocates the result
    /// via `allocator`; the caller must free it.
    ///
    /// The iterator is exhausted after this call (`next()` returns `null`), but
    /// `deinit()` is still required to release the RCU reader token.
    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        var out = try std.ArrayList(types.NodeId).initCapacity(allocator, snapshotDegree(self));
        errdefer out.deinit(allocator);
        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn snapshotDegree(iterator: *const NeighborIterator) usize {
    if (!iterator.reader_active) return 0;
    if (!rcu.readerTokenActive(iterator.reader_token)) {
        @constCast(iterator).reader_active = false;
        return 0;
    }
    return iterator.degree_snapshot;
}

/// Drains all remaining items into a caller-owned slice and consumes the
/// iterator. Internal callers use this helper when the RCU guard lifetime
/// should end as part of materialization.
pub fn materializeConsuming(iterator: *NeighborIterator, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    defer iterator.deinit();
    var out = try std.ArrayList(types.NodeId).initCapacity(allocator, snapshotDegree(iterator));
    errdefer out.deinit(allocator);
    while (iterator.next()) |neighbor| {
        try out.append(allocator, neighbor);
    }
    return out.toOwnedSlice(allocator);
}

pub fn materializeExactConsuming(iterator: *NeighborIterator, allocator: std.mem.Allocator, capacity: usize) types.GraphError![]types.NodeId {
    defer iterator.deinit();
    const snapshot_capacity = snapshotDegree(iterator);
    var out = try std.ArrayList(types.NodeId).initCapacity(allocator, @max(capacity, snapshot_capacity));
    errdefer out.deinit(allocator);
    while (iterator.next()) |neighbor| {
        try out.append(allocator, neighbor);
    }
    return out.toOwnedSlice(allocator);
}

fn sideAdj(direction: Direction, node_adj: types.NodeAdj) types.SideAdj {
    return switch (direction) {
        .fwd => .{
            .first_block = node_adj.first_block_fwd,
            .block_count = node_adj.block_count_fwd,
            .group_count = node_adj.group_count_fwd,
            .first_group = node_adj.first_group_fwd,
        },
        .rev => .{
            .first_block = node_adj.first_block_rev,
            .block_count = node_adj.block_count_rev,
            .group_count = node_adj.group_count_rev,
            .first_group = node_adj.first_group_rev,
        },
    };
}

fn initNeighborIterator(graph: *const graph_core.GraphCore, node: types.NodeId, direction: Direction) types.GraphError!NeighborIterator {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const reader_token = try rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const meta = node_buffer.loadPublishedMeta();
    const node_adj_snapshot = node_buffer.publishedAdjFromMeta(meta);
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);
    const side_snapshot = sideAdj(direction, node_adj_snapshot);
    if (direction == .fwd) {
        try iterator_common.validateReadSideQuick(graph, side_snapshot, .fwd);
    } else {
        try iterator_common.validateReadSideQuick(graph, side_snapshot, .rev);
    }

    const initial = iterator_common.buildTraversalState(side_snapshot);

    var iterator = NeighborIterator{
        .core = graph,
        .direction = direction,
        .node_adj_snapshot = node_adj_snapshot,
        .contiguous_mode = initial.contiguous_mode,
        .current_block_index = initial.current_block_index,
        .blocks_remaining = initial.blocks_remaining,
        .current_group_index = initial.current_group_index,
        .current_mask = 0,
        .degree_snapshot = switch (direction) {
            .fwd => meta.degree_fwd,
            .rev => meta.degree_rev,
        },
        .reader_active = true,
        .reader_token = reader_token,
        .groups_visited = 0,
        .group_count_bound = switch (direction) {
            .fwd => node_adj_snapshot.group_count_fwd,
            .rev => node_adj_snapshot.group_count_rev,
        },
    };

    iterator_common.primeGroupedTraversal(&iterator, graph);

    return iterator;
}

pub fn neighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .fwd);
}

pub fn inNeighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .rev);
}

pub fn outDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const meta = node_buffer.loadPublishedMeta();
    if (meta.removed) return error.InvalidNode;
    return meta.degree_fwd;
}

pub fn inDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const meta = node_buffer.loadPublishedMeta();
    if (meta.removed) return error.InvalidNode;
    return meta.degree_rev;
}
