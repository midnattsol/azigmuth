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
    meta: types.PublishedMeta,
    node_adj_snapshot: types.NodeAdj,
};

pub fn sideAdj(direction: enum { fwd, rev }, node_adj: types.NodeAdj) types.SideAdj {
    return switch (direction) {
        .fwd => .{ .first_block = node_adj.first_block_fwd, .block_count = node_adj.block_count_fwd, .group_count = node_adj.group_count_fwd, .first_group = node_adj.first_group_fwd },
        .rev => .{ .first_block = node_adj.first_block_rev, .block_count = node_adj.block_count_rev, .group_count = node_adj.group_count_rev, .first_group = node_adj.first_group_rev },
    };
}

/// Captures a reader-guarded published node snapshot for live iteration.
pub fn captureNodeSnapshot(graph: *const graph_core.GraphCore, node: types.NodeId) types.GraphError!LiveReadSnapshot {
    if (!node_validity.nodeExistsRaw(graph, node)) return error.InvalidNode;

    const reader_token = try rcu.readerEnter(@constCast(graph));
    errdefer rcu.readerExit(@constCast(graph), reader_token);

    const node_buffer = node_access.nodeAtConst(graph, node);
    const meta = node_access.loadPublishedMeta(node_buffer);
    const node_adj_snapshot = node_access.publishedAdjFromMetaAtConst(graph, node, meta);
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);

    return .{ .reader_token = reader_token, .meta = meta, .node_adj_snapshot = node_adj_snapshot };
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
pub fn candidateRemoved(iterator: anytype, graph: *const graph_core.GraphCore, candidate_index: u32) bool {
    if (candidate_index >= graph.publishedNodeCount()) return true;
    const page_index = page_ops.pageOf(candidate_index, constants.NODES_PER_PAGE);
    if (iterator.cached_node_page == null or iterator.cached_node_page_index != page_index) {
        iterator.cached_node_page = page_ops.nodeMetaPageAtConst(graph, page_index);
        iterator.cached_node_page_index = page_index;
    }

    const slot_index = page_ops.slotOf(candidate_index, constants.NODES_PER_PAGE);
    return iterator.cached_node_page.?[slot_index].loadPublishedMeta().removed;
}

/// Releases the reader token held by one live iterator, if still active.
pub fn deinitReader(iterator: anytype, graph: *const graph_core.GraphCore) void {
    if (!iterator.reader_active) return;

    switch (rcu.beginCloseReaderToken(graph, iterator.reader_token)) {
        .inactive => {},
        .pending => {},
        .finalize => rcu.finalizeReaderExit(@constCast(graph), iterator.reader_token),
    }
    iterator.reader_active = false;
}
