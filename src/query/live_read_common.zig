const graph_core = @import("../core/graph_core.zig");
const constants = @import("../core/constants.zig");
const node_access = @import("../core/node_access.zig");
const side_traversal = @import("side_traversal.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const rcu = @import("../concurrency/rcu.zig");
const node_validity = @import("../core/node_validity.zig");
const adjacency = @import("../adjacency/mod.zig");

pub const LiveReadSnapshot = struct {
    reader_token: rcu.ReaderToken,
    /// True when `reader_token` is a retain on a longer-lived owner (a
    /// ReadSession): release the retain on exit instead of closing the token.
    token_retained: bool = false,
    meta: types.PublishedMeta,
    node_adj_snapshot: types.NodeAdj,
    degree_fwd: u32,
    degree_rev: u32,
    sorted_fwd: bool,
    sorted_rev: bool,
};

/// Undoes `captureNodeSnapshot`'s reader acquisition on error paths.
pub fn releaseCapturedReader(graph: *const graph_core.GraphCore, capture: LiveReadSnapshot) void {
    if (capture.token_retained) {
        switch (rcu.releaseRetainedReaderToken(graph, capture.reader_token)) {
            .alive, .closed => {},
            .finalize => rcu.finalizeReaderExit(@constCast(graph), capture.reader_token),
        }
        return;
    }
    rcu.readerExit(@constCast(graph), capture.reader_token);
}

pub fn sideAdj(direction: enum { fwd, rev }, node_adj: types.NodeAdj) types.SideAdj {
    return switch (direction) {
        .fwd => .{ .first_block = node_adj.first_block_fwd, .block_count = node_adj.block_count_fwd, .group_count = node_adj.group_count_fwd, .first_group = node_adj.first_group_fwd },
        .rev => .{ .first_block = node_adj.first_block_rev, .block_count = node_adj.block_count_rev, .group_count = node_adj.group_count_rev, .first_group = node_adj.first_group_rev },
    };
}

/// Captures a reader-guarded published node snapshot for live iteration.
///
/// The composed `NodeAdj` and degrees are read from the per-side
/// double-buffers, which a subsequent writer may recycle as staging the
/// moment one publish flips the side index. The seqlock-style re-read of
/// `published_meta` below is therefore mandatory: it guarantees the slots
/// were not overwritten while being read, so the snapshot is never a torn
/// mix of two published versions (the seqlock reader rule).
pub fn captureNodeSnapshot(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!LiveReadSnapshot {
    return captureNodeSnapshotImpl(graph, node, null);
}

/// Like captureNodeSnapshot, but retains `session_token` (one atomic
/// increment) instead of allocating a fresh reader slot + tracked token —
/// the cheap path for ReadSession point reads. Falls back to a fresh token
/// when the retain fails (saturated or closing).
pub fn captureNodeSnapshotRetained(graph: *const graph_core.GraphCore, node: types.NodeId, session_token: rcu.ReaderToken) types.GraphError!LiveReadSnapshot {
    return captureNodeSnapshotImpl(graph, node, session_token);
}

fn captureNodeSnapshotImpl(graph: *const graph_core.GraphCore, node: types.NodeId, session_token: ?rcu.ReaderToken) types.GraphError!LiveReadSnapshot {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    var token_retained = false;
    const reader_token = blk: {
        if (session_token) |token| {
            if (rcu.tryRetainReaderToken(graph, token)) {
                token_retained = true;
                break :blk token;
            }
        }
        break :blk try rcu.readerEnter(@constCast(graph));
    };
    errdefer if (token_retained) {
        switch (rcu.releaseRetainedReaderToken(graph, reader_token)) {
            .alive, .closed => {},
            .finalize => rcu.finalizeReaderExit(@constCast(graph), reader_token),
        }
    } else rcu.readerExit(@constCast(graph), reader_token);

    const published_ref = node_access.nodePublishedAtConst(graph, node);
    var meta = node_access.loadPublishedMetaAtConst(graph, node);
    while (true) {
        const node_adj_snapshot = node_access.publishedAdjFromMetaAtConst(graph, node, meta);
        const degree_fwd = node_access.publishedFwdDegreeFromMetaAtConst(graph, node, meta);
        const degree_rev = node_access.publishedRevDegreeFromMetaAtConst(graph, node, meta);
        const sorted_fwd = published_ref.publishedFwdSortedFromMeta(meta);
        const sorted_rev = published_ref.publishedRevSortedFromMeta(meta);

        const after = node_access.loadPublishedMetaAtConst(graph, node);
        if (@as(u64, @bitCast(meta)) == @as(u64, @bitCast(after))) {
            try node_validity.ensureLiveSnapshot(node_adj_snapshot);
            return .{
                .reader_token = reader_token,
                .token_retained = token_retained,
                .meta = meta,
                .node_adj_snapshot = node_adj_snapshot,
                .degree_fwd = degree_fwd,
                .degree_rev = degree_rev,
                .sorted_fwd = sorted_fwd,
                .sorted_rev = sorted_rev,
            };
        }
        meta = after;
    }
}

pub fn validateForwardSideQuick(graph: *const graph_core.GraphCore, side_snapshot: types.SideAdj) types.GraphError!void {
    try side_traversal.validateReadSideQuick(graph, side_snapshot, .fwd);
}

pub fn validateReverseSideQuick(graph: *const graph_core.GraphCore, side_snapshot: types.SideAdj) types.GraphError!void {
    try side_traversal.validateReadSideQuick(graph, side_snapshot, .rev);
}

/// Returns whether a candidate node should be treated as removed during live iteration.
/// Caches the candidate's NodeMeta page: 8 bytes per node keeps the removed
/// filter dense in cache during multi-candidate scans.
pub fn candidateRemoved(iterator: anytype, graph: *const graph_core.GraphCore, candidate_idx: u32) bool {
    if (candidate_idx >= graph.publishedNodeCount()) return true;
    const page_idx = page_ops.pageOf(candidate_idx, constants.NODES_PER_PAGE);
    if (iterator.cached_node_page == null or iterator.cached_node_page_idx != page_idx) {
        iterator.cached_node_page = page_ops.nodeMetaPageAtConst(graph, page_idx);
        iterator.cached_node_page_idx = page_idx;
    }

    const slot_idx = page_ops.slotOf(candidate_idx, constants.NODES_PER_PAGE);
    return iterator.cached_node_page.?[slot_idx].loadPublishedMeta().removed;
}

/// Releases the reader token held by one live iterator, if still active.
pub fn deinitReader(iterator: anytype, graph: *const graph_core.GraphCore) void {
    if (!iterator.reader_active) return;

    if (iterator.reader_token_retained) {
        switch (rcu.releaseRetainedReaderToken(graph, iterator.reader_token)) {
            .alive, .closed => {},
            .finalize => rcu.finalizeReaderExit(@constCast(graph), iterator.reader_token),
        }
        iterator.reader_active = false;
        return;
    }

    switch (rcu.beginCloseReaderToken(graph, iterator.reader_token)) {
        .inactive => {},
        .pending => {},
        .finalize => rcu.finalizeReaderExit(@constCast(graph), iterator.reader_token),
    }
    iterator.reader_active = false;
}
