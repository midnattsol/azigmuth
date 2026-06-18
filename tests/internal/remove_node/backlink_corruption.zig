const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const constants = graph_mod.constants_mod;
const publish = @import("publish");
const testing = std.testing;

test "removeNode corruption: missing reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const destination_adj = try graph.publishedNodeAdj(destination);
    if (destination_adj.block_count_rev > 0 and destination_adj.segment_count_rev == 0 and publish.reverseLiveCount(&graph, destination_adj) catch 0 > 0) {
        try publish.writeReverseSource(&graph, destination_adj, 0, graph.graph.publishedNodeCount() + 10);
    } else if (destination_adj.block_count_rev > 0 and destination_adj.segment_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, destination_adj.first_block_rev, .rev);
        const alive = page_ops.blockAliveCount(&graph.graph, destination_adj.first_block_rev, .rev);
        var found = false;
        for (0..alive) |slot| {
            if (block.sources[slot] == source.index) {
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}

test "removeNode corruption: duplicated reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const destination_adj = try graph.publishedNodeAdj(destination);
    if (destination_adj.block_count_rev > 0 and destination_adj.segment_count_rev == 0) {
        try publish.appendReverseSource(&graph, destination, destination_adj, source.index);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}

test "removeNode corruption: missing incoming reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed_node, 0, 0);

    const removed_node_adj = try graph.publishedNodeAdj(removed_node);
    if (removed_node_adj.block_count_rev > 0 and removed_node_adj.segment_count_rev == 0 and publish.reverseLiveCount(&graph, removed_node_adj) catch 0 > 0) {
        try publish.writeReverseSource(&graph, removed_node_adj, 0, graph.graph.publishedNodeCount() + 10);
    } else if (removed_node_adj.block_count_rev > 0 and removed_node_adj.segment_count_rev == 0) {
        const block = page_ops.edgeBlockAt(&graph.graph, removed_node_adj.first_block_rev, .rev);
        const alive = page_ops.blockAliveCount(&graph.graph, removed_node_adj.first_block_rev, .rev);
        var found = false;
        for (0..alive) |slot| {
            if (block.sources[slot] == source.index) {
                block.sources[slot] = graph.graph.publishedNodeCount() + 10;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(removed_node));
}

test "removeNode corruption: duplicated incoming reverse backlink is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_node = try graph.addNode();
    const source = try graph.addNode();
    try graph.addEdge(source, removed_node, 0, 0);

    const removed_node_adj = try graph.publishedNodeAdj(removed_node);
    if (removed_node_adj.block_count_rev > 0 and removed_node_adj.segment_count_rev == 0) {
        try publish.appendReverseSource(&graph, removed_node, removed_node_adj, source.index);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(removed_node));
}

test "removeNode corruption: duplicated outgoing forward destination is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const source_adj = try graph.publishedNodeAdj(source);
    if (source_adj.block_count_fwd > 0 and source_adj.segment_count_fwd == 0) {
        const last_entry = try publish.readForwardEntry(&graph, source_adj, (try publish.forwardLiveCount(&graph, source_adj)) - 1);
        try publish.appendForwardEntry(&graph, source, source_adj, last_entry);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}

test "removeNode corruption: forward destination out of range is rejected" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const adj = try graph.publishedNodeAdj(source);
    if (adj.block_count_fwd > 0 and adj.segment_count_fwd == 0) {
        try publish.writeForwardDestination(&graph, adj, 0, graph.graph.publishedNodeCount() + 1);
    }

    try testing.expectError(error.CorruptGraph, graph.removeNode(source));
}
