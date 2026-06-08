const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const common = @import("common.zig");
const node_validity = @import("../core/node_validity.zig");
const remove_types = @import("node_remove_types.zig");

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
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const destination_idx = block.edges[slot].destination;
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
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const source_idx = block.sources[slot];
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
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();

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
    const node_buffer = page_ops.nodeAtConst(graph, node);
    const published_adj = node_buffer.publishedAdj();

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
