const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");

/// Adds one new live node and returns its assigned node id.
pub fn addNode(graph: *graph_core.GraphCore) !types.NodeId {
    while (true) {
        const node_idx = graph.publishedNodeCount();
        // Node ids are u32; the directory ceiling may exceed the index space.
        if (node_idx == std.math.maxInt(u32)) return error.OutOfMemory;
        const page_idx = page_ops.pageOf(node_idx, constants.NODES_PER_PAGE);
        _ = try page_ops.ensureNodePublicationPage(graph, page_idx);
        _ = try page_ops.ensureNodeMutationControlPage(graph, page_idx);
        _ = try page_ops.ensureNodeAdjacencyBufferPage(graph, page_idx);
        page_ops.nodeMutationControlAt(graph, .{ .index = node_idx }).storeNextLocalEdgeId(1);

        if (graph.node_count.cmpxchgWeak(node_idx, node_idx + 1, .acq_rel, .acquire) == null) {
            return .{ .index = node_idx };
        }
    }
}
