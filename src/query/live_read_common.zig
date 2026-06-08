const graph_core = @import("../core/graph_core.zig");
const iterator_common = @import("iterator_common.zig");
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

/// Extracts one side view from a full published node adjacency snapshot.
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

    const node_buffer = page_ops.nodeAtConst(graph, node);
    const meta = node_buffer.loadPublishedMeta();
    const node_adj_snapshot = node_buffer.publishedAdjFromMeta(meta);
    try node_validity.ensureLiveSnapshot(node_adj_snapshot);

    return .{ .reader_token = reader_token, .meta = meta, .node_adj_snapshot = node_adj_snapshot };
}

/// Validates the basic layout of one forward side snapshot before iteration.
pub fn validateForwardSideQuick(graph: *const graph_core.GraphCore, side_snapshot: types.SideAdj) types.GraphError!void {
    try iterator_common.validateReadSideQuick(graph, side_snapshot, .fwd);
}

/// Validates the basic layout of one reverse side snapshot before iteration.
pub fn validateReverseSideQuick(graph: *const graph_core.GraphCore, side_snapshot: types.SideAdj) types.GraphError!void {
    try iterator_common.validateReadSideQuick(graph, side_snapshot, .rev);
}
