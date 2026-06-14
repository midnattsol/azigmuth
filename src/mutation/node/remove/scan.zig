const graph_core = @import("../../../core/graph_core.zig");
const node_access = @import("../../../core/node_access.zig");
const types = @import("../../../core/types.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const node_published = @import("../../../storage/node/published.zig");
const side_ops = @import("../../../adjacency/side_ops.zig");
const common = @import("../../common.zig");
const node_validity = @import("../../../core/node_validity.zig");
const remove_types = @import("types.zig");

const ForwardDestinationCollection = struct {
    source_idx: u32,
    node_count: u32,
    scan: *remove_types.RemovalScan,
};

fn appendForwardDestination(
    graph: *const graph_core.GraphCore,
    collection: *ForwardDestinationCollection,
    block_idx: u32,
    slot: u7,
) !void {
    const destination_idx = if ((block_idx & side_ops.TINY_SLOT_TAG) != 0)
        page_ops.tinyBlockAtConst(graph, block_idx & ~side_ops.TINY_SLOT_TAG, .fwd).entries[slot].destination
    else
        page_ops.edgeBlockAtConst(graph, block_idx, .fwd).destinations[slot];
    if (destination_idx >= collection.node_count) return error.CorruptGraph;
    try collection.scan.forward_destinations.append(graph.allocator, destination_idx);
    if (node_validity.isNodeLiveIndex(graph, destination_idx)) {
        collection.scan.visible_forward += 1;
    }
    if (destination_idx == collection.source_idx) {
        collection.scan.self_edge_count += 1;
    }
}

const ReverseSourceCollection = struct {
    node_count: u32,
    source_idx: u32,
    scan: *remove_types.RemovalScan,
};

fn appendReverseSource(
    graph: *const graph_core.GraphCore,
    collection: *ReverseSourceCollection,
    block_idx: u32,
    slot: u7,
) !void {
    const source_idx = if ((block_idx & side_ops.TINY_SLOT_TAG) != 0)
        page_ops.tinyBlockAtConst(graph, block_idx & ~side_ops.TINY_SLOT_TAG, .rev).sources[slot]
    else
        page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot];
    if (source_idx >= collection.node_count) return error.CorruptGraph;
    try collection.scan.reverse_sources.append(graph.allocator, source_idx);
    if (source_idx != collection.source_idx and node_validity.isNodeLiveIndex(graph, source_idx)) {
        collection.scan.visible_incoming += 1;
    }
}

fn collectForwardDestinations(
    graph: *const graph_core.GraphCore,
    node: types.NodeId,
    scan: *remove_types.RemovalScan,
) !void {
    const node_count = graph.publishedNodeCount();
    const published_adj = node_access.publishedAdjAtConst(graph, node);
    const side_view = common.sideAdjOfNode(published_adj, .fwd);

    if (node_published.NodePublished.isTiny(&side_view)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_view.first_block, .fwd);
        const count = node_published.NodePublished.tinyCount(&side_view);
        for (0..count) |entry_idx| {
            const destination_idx = slot.entries[entry_idx].destination;
            if (destination_idx >= node_count) return error.CorruptGraph;
            try scan.forward_destinations.append(graph.allocator, destination_idx);
            if (node_validity.isNodeLiveIndex(graph, destination_idx)) scan.visible_forward += 1;
            if (destination_idx == node.index) scan.self_edge_count += 1;
        }
        return;
    }

    var collection = ForwardDestinationCollection{
        .source_idx = node.index,
        .node_count = node_count,
        .scan = scan,
    };
    try common.forEachSlotInSide(
        graph,
        common.sideAdjOfNode(published_adj, .fwd),
        .fwd,
        &collection,
        appendForwardDestination,
    );
}

fn collectReverseSources(
    graph: *const graph_core.GraphCore,
    node: types.NodeId,
    scan: *remove_types.RemovalScan,
) !void {
    const published_adj = node_access.publishedAdjAtConst(graph, node);
    const side_view = common.sideAdjOfNode(published_adj, .rev);

    if (node_published.NodePublished.isTiny(&side_view)) {
        const slot = page_ops.tinyBlockAtConst(graph, side_view.first_block, .rev);
        const count = node_published.NodePublished.tinyCount(&side_view);
        for (0..count) |entry_idx| {
            const source_idx = slot.sources[entry_idx];
            if (source_idx >= graph.publishedNodeCount()) return error.CorruptGraph;
            try scan.reverse_sources.append(graph.allocator, source_idx);
            if (source_idx != node.index and node_validity.isNodeLiveIndex(graph, source_idx)) scan.visible_incoming += 1;
        }
        return;
    }

    var collection = ReverseSourceCollection{
        .node_count = graph.publishedNodeCount(),
        .source_idx = node.index,
        .scan = scan,
    };
    try common.forEachSlotInSide(
        graph,
        common.sideAdjOfNode(published_adj, .rev),
        .rev,
        &collection,
        appendReverseSource,
    );
}

/// Scans the forward and reverse neighborhood that will be affected by removeNode.
/// Returns caller-owned scan buffers that must later be deinitialized.
pub fn scanNodeRemovalNeighborhood(
    graph: *const graph_core.GraphCore,
    node: types.NodeId,
) !remove_types.RemovalScan {
    var scan = remove_types.RemovalScan{};
    errdefer scan.deinit(graph.allocator);

    try collectForwardDestinations(graph, node, &scan);
    try collectReverseSources(graph, node, &scan);

    return scan;
}
