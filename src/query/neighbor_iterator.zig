//! Canonical neighbor iterator type shared by the public API and internal query
//! helpers. Returned by value; creation does not allocate. Iterators are
//! logically single-owner values: copying and using multiple copies is
//! unsupported.

const std = @import("std");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const node_access = @import("../core/node_access.zig");
const side_ops = @import("../adjacency/side_ops.zig");
const side_traversal = @import("side_traversal.zig");
const live_read_common = @import("live_read_common.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const node_published = @import("../storage/node/published.zig");
const node_meta_mod = @import("../storage/node/meta.zig");
const node_tiny = @import("../storage/node/tiny.zig");
const rcu = @import("../concurrency/rcu.zig");
const node_validity = @import("../core/node_validity.zig");

pub const Direction = enum { fwd, rev };

pub const NeighborIterator = struct {
    core: *const graph_core.GraphCore,
    direction: Direction,
    node_adj_snapshot: types.NodeAdj,

    contiguous_mode: bool,
    current_block_index: u32,
    blocks_remaining: u32,
    current_group_index: u32,

    current_slot: u7 = 0,
    current_live: u7 = 0,
    tiny_mode: bool = false,
    tiny_slot: u32 = 0,
    tiny_count: u16 = 0,
    tiny_index: u16 = 0,
    /// Cached from loadNextNonEmptyMask so next() avoids a second block fetch.
    cached_fwd_block: ?*const types.EdgeBlockFwd = null,
    cached_rev_block: ?*const types.EdgeBlockRev = null,
    cached_tiny_fwd: ?*const node_tiny.TinyFwdSlot = null,
    cached_tiny_rev: ?*const node_tiny.TinyRevSlot = null,
    cached_span_page_index: u32 = constants.END_OF_CHAIN,
    cached_span_blocks_raw: usize = 0,
    cached_span_live_raw: usize = 0,
    cached_node_page_index: u32 = constants.END_OF_CHAIN,
    cached_node_page: ?[]const node_meta_mod.NodeMeta = null,

    degree_snapshot: usize,
    check_removed_candidates: bool,

    reader_active: bool,
    reader_token: rcu.ReaderToken,
    reader_token_retained: bool = false,

    /// Safeguard against corrupt cyclic group chains: stop advancing
    /// after visiting more groups than the adjacency snapshot declares.
    groups_visited: u16 = 0,
    group_count_bound: u16 = 0,

    fn advanceToNextGroup(self: *NeighborIterator) bool {
        return side_traversal.advanceToNextGroup(self, self.core);
    }

    fn candidateRemoved(self: *NeighborIterator, candidate_index: u32) bool {
        if (!self.check_removed_candidates) return false;
        return live_read_common.candidateRemoved(self, self.core, candidate_index);
    }

    fn nextTinyNeighbor(self: *NeighborIterator) ?types.NodeId {
        while (self.tiny_index < self.tiny_count) : (self.tiny_index += 1) {
            const candidate_idx = switch (self.direction) {
                .fwd => self.cached_tiny_fwd.?.entries[self.tiny_index].destination,
                .rev => self.cached_tiny_rev.?.sources[self.tiny_index],
            };
            if (self.candidateRemoved(candidate_idx)) continue;
            self.tiny_index += 1;
            return types.NodeId{ .index = candidate_idx };
        }
        return null;
    }

    fn nextBlockNeighbor(self: *NeighborIterator) ?types.NodeId {
        while (true) {
            while (self.current_slot >= self.current_live) {
                // Token liveness is validated once per block span, not per
                // neighbor: a span's cached block pointer stays valid while
                // the token pins its epoch, so the per-element atomic load
                // would only re-confirm the same fact 64 times.
                if (!rcu.readerTokenActive(self.core, self.reader_token)) {
                    self.reader_active = false;
                    return null;
                }
                if (!side_traversal.loadNextNeighborSpan(self, self.core)) return null;
            }

            const slot = self.current_slot;
            self.current_slot += 1;
            const candidate = switch (self.direction) {
                .fwd => types.NodeId{ .index = self.cached_fwd_block.?.destinations[slot] },
                .rev => types.NodeId{ .index = self.cached_rev_block.?.sources[slot] },
            };
            if (self.candidateRemoved(candidate.index)) continue;
            return candidate;
        }
    }

    pub fn next(self: *NeighborIterator) ?types.NodeId {
        if (!self.reader_active) return null;
        if (self.tiny_mode) {
            if (!rcu.readerTokenActive(self.core, self.reader_token)) {
                self.reader_active = false;
                return null;
            }
            return self.nextTinyNeighbor();
        }
        return self.nextBlockNeighbor();
    }

    pub fn deinit(self: *NeighborIterator) void {
        live_read_common.deinitReader(self, self.core);
    }

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
    if (!rcu.readerTokenActive(iterator.core, iterator.reader_token)) {
        @constCast(iterator).reader_active = false;
        return 0;
    }
    return iterator.degree_snapshot;
}

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

fn initNeighborIterator(graph: *const graph_core.GraphCore, node: types.NodeId, direction: Direction) types.GraphError!NeighborIterator {
    return initNeighborIteratorWithCapture(graph, try live_read_common.captureNodeSnapshot(graph, node), direction);
}

fn initNeighborIteratorWithCapture(graph: *const graph_core.GraphCore, capture: live_read_common.LiveReadSnapshot, direction: Direction) types.GraphError!NeighborIterator {
    errdefer live_read_common.releaseCapturedReader(graph, capture);
    const side_snapshot = live_read_common.sideAdj(switch (direction) {
        .fwd => .fwd,
        .rev => .rev,
    }, capture.node_adj_snapshot);
    switch (direction) {
        .fwd => try live_read_common.validateForwardSideQuick(graph, side_snapshot),
        .rev => try live_read_common.validateReverseSideQuick(graph, side_snapshot),
    }

    const cursor_init = side_traversal.buildCursorInit(side_snapshot);

    var iterator = NeighborIterator{
        .core = graph,
        .direction = direction,
        .node_adj_snapshot = capture.node_adj_snapshot,
        .contiguous_mode = cursor_init.traversal.contiguous_mode,
        .current_block_index = cursor_init.traversal.current_block_index,
        .blocks_remaining = cursor_init.traversal.blocks_remaining,
        .current_group_index = cursor_init.traversal.current_group_index,
        .tiny_mode = cursor_init.tiny.tiny_mode,
        .tiny_slot = cursor_init.tiny.tiny_slot,
        .tiny_count = cursor_init.tiny.tiny_count,
        .degree_snapshot = switch (direction) {
            .fwd => capture.degree_fwd,
            .rev => capture.degree_rev,
        },
        .check_removed_candidates = switch (direction) {
            .fwd => capture.node_adj_snapshot.flags.needs_repair_fwd,
            .rev => capture.node_adj_snapshot.flags.needs_repair_rev,
        },
        .reader_active = true,
        .reader_token = capture.reader_token,
        .reader_token_retained = capture.token_retained,
        .groups_visited = 0,
        .group_count_bound = cursor_init.group_count_bound,
    };

    if (iterator.tiny_mode) {
        switch (direction) {
            .fwd => iterator.cached_tiny_fwd = page_ops.tinyFwdAtConst(graph, iterator.tiny_slot),
            .rev => iterator.cached_tiny_rev = page_ops.tinyRevAtConst(graph, iterator.tiny_slot),
        }
    }
    side_traversal.primeGroupedTraversal(&iterator, graph);

    return iterator;
}

pub fn neighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .fwd);
}

pub fn inNeighbors(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!NeighborIterator {
    return initNeighborIterator(graph, node, .rev);
}

/// Session point-read entry: the iterator retains the session's reader token
/// (one atomic increment) instead of opening its own reader critical section.
pub fn neighborsRetained(graph: *const graph_core.GraphCore, node: types.NodeId, session_token: rcu.ReaderToken) types.GraphError!NeighborIterator {
    return initNeighborIteratorWithCapture(graph, try live_read_common.captureNodeSnapshotRetained(graph, node, session_token), .fwd);
}

pub fn inNeighborsRetained(graph: *const graph_core.GraphCore, node: types.NodeId, session_token: rcu.ReaderToken) types.GraphError!NeighborIterator {
    return initNeighborIteratorWithCapture(graph, try live_read_common.captureNodeSnapshotRetained(graph, node, session_token), .rev);
}

pub fn outDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    const meta = node_access.loadPublishedMetaAtConst(graph, node);
    if (meta.removed) return error.InvalidNode;
    return node_access.publishedFwdDegreeAtConst(graph, node);
}

pub fn inDegree(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!usize {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;
    const meta = node_access.loadPublishedMetaAtConst(graph, node);
    if (meta.removed) return error.InvalidNode;
    return node_access.publishedRevDegreeAtConst(graph, node);
}
