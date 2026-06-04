//! Canonical neighbor iterator type shared by the public API and internal query
//! helpers. Returned by value; creation does not allocate.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
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
    current_block_for_mask: u32,
    /// Cached from loadNextNonEmptyMask so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,

    reader_active: bool,
    reader_token: rcu.ReaderToken,

    /// Safeguard against corrupt cyclic group chains: stop advancing
    /// after visiting more groups than the adjacency snapshot declares.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *NeighborIterator) bool {
        if (self.contiguous_mode) return false;
        if (self.current_group_index == constants.END_OF_CHAIN) return false;

        const current = page_ops.groupAtConst(self.core, self.current_group_index);
        if (current.next == constants.END_OF_CHAIN) {
            self.current_group_index = constants.END_OF_CHAIN;
            return false;
        }

        self.current_group_index = current.next;
        self.groups_visited += 1;
        if (self.groups_visited >= self.group_count_bound) {
            self.current_group_index = constants.END_OF_CHAIN;
            return false;
        }

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
        if (!self.reader_active) return null;
        if (!rcu.tryRetainReaderToken(self.reader_token)) {
            self.reader_active = false;
            return null;
        }
        defer {
            switch (rcu.releaseRetainedReaderToken(self.reader_token)) {
                .alive => {},
                .closed => self.reader_active = false,
                .finalize => {
                    self.reader_active = false;
                    rcu.finalizeReaderExit(@constCast(self.core), self.reader_token);
                },
            }
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
            if (!node_validity.isNodeLive(self.core, candidate)) continue;
            return candidate;
        }
    }

    pub fn deinit(self: *NeighborIterator) void {
        if (!self.reader_active) return;
        switch (rcu.beginCloseReaderToken(self.reader_token)) {
            .inactive => {},
            .pending => {},
            .finalize => rcu.finalizeReaderExit(@constCast(self.core), self.reader_token),
        }
        self.reader_active = false;
    }

    /// Drains remaining items into a caller-owned slice. Allocates the result
    /// via `allocator`; the caller must free it.
    ///
    /// The iterator is exhausted after this call (`next()` returns `null`), but
    /// `deinit()` is still required to release the RCU reader token.
    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
        var out: std.ArrayList(types.NodeId) = .empty;
        errdefer out.deinit(allocator);
        while (self.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn snapshotDegree(iterator: *const NeighborIterator) usize {
    if (!iterator.reader_active) return 0;
    if (!rcu.tryRetainReaderToken(iterator.reader_token)) {
        @constCast(iterator).reader_active = false;
        return 0;
    }
    defer {
        switch (rcu.releaseRetainedReaderToken(iterator.reader_token)) {
            .alive => {},
            .closed => @constCast(iterator).reader_active = false,
            .finalize => {
                @constCast(iterator).reader_active = false;
                rcu.finalizeReaderExit(@constCast(iterator.core), iterator.reader_token);
            },
        }
    }
    return switch (iterator.direction) {
        .fwd => sumVisibleCount(iterator.core, iterator.node_adj_snapshot, .fwd),
        .rev => sumVisibleCount(iterator.core, iterator.node_adj_snapshot, .rev),
    };
}

/// Drains all remaining items into a caller-owned slice and consumes the
/// iterator. Internal callers use this helper when the RCU guard lifetime
/// should end as part of materialization.
pub fn materializeConsuming(iterator: *NeighborIterator, allocator: std.mem.Allocator) types.GraphError![]types.NodeId {
    defer iterator.deinit();
    var out = try std.ArrayList(types.NodeId).initCapacity(allocator, snapshotDegree(iterator));
    while (iterator.next()) |neighbor| {
        out.appendAssumeCapacity(neighbor);
    }
    return out.toOwnedSlice(allocator);
}

pub fn materializeExactConsuming(iterator: *NeighborIterator, allocator: std.mem.Allocator, capacity: usize) types.GraphError![]types.NodeId {
    defer iterator.deinit();
    const snapshot_capacity = snapshotDegree(iterator);
    var out = try std.ArrayList(types.NodeId).initCapacity(allocator, @max(capacity, snapshot_capacity));
    while (iterator.next()) |neighbor| {
        out.appendAssumeCapacity(neighbor);
    }
    return out.toOwnedSlice(allocator);
}

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
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const reader_token = try rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const node_adj_snapshot = node_buffer.publishedAdj();
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);

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
        .groups_visited = 0,
        .group_count_bound = switch (direction) {
            .fwd => node_adj_snapshot.group_count_fwd,
            .rev => node_adj_snapshot.group_count_rev,
        },
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

fn countVisibleEntriesInBlock(graph: *const graph_core.GraphCore, block_index: u32, comptime side: Direction) usize {
    const block = page_ops.edgeBlockAtConst(graph, block_index, switch (side) {
        .fwd => .fwd,
        .rev => .rev,
    });
    const live = @popCount(block.mask);
    var total: usize = 0;
    for (0..live) |slot| {
        const candidate_index = switch (side) {
            .fwd => block.edges[slot].destination,
            .rev => block.sources[slot],
        };
        if (node_validity.isNodeLiveIndex(graph, candidate_index)) total += 1;
    }
    return total;
}

fn sumVisibleCount(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, comptime side: Direction) usize {
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
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        return total;
    }

    var group_idx: u32 = switch (side) {
        .fwd => node_adj.first_group_fwd,
        .rev => node_adj.first_group_rev,
    };
    var visited: u16 = 0;
    while (visited < group_count) : (visited += 1) {
        if (group_idx == constants.END_OF_CHAIN) break;
        const group = page_ops.groupAtConst(graph, group_idx);
        for (group.start..group.start + group.count) |block_index| {
            total += countVisibleEntriesInBlock(graph, @intCast(block_index), side);
        }
        group_idx = group.next;
    }

    return total;
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
