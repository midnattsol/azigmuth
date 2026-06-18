const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const repair = graph_mod.repair_mod;
const types = graph_mod.types_mod;
const adjacency_mod = graph_mod.adjacency_mod;
const publish = @import("publish");

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn fillForwardBlock(graph: *graph_mod.Graph, block_idx: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .fwd);
    for (0..count) |edge_idx| {
        block.destinations[edge_idx] = first_destination + @as(u32, @intCast(edge_idx));
        block.relations[edge_idx] = 0;
        block.flags[edge_idx] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .fwd, @intCast(count));
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination_idx: u32, source_idx: u32) !void {
    const block_idx = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_idx, .rev);
    block.sources[0] = source_idx;
    page_ops.setBlockAliveCount(&graph.graph, block_idx, .rev, @intCast(1));

    const node_buffer = try graph.nodeAt(.{ .index = destination_idx });
    publish.publishedRevSide(node_buffer).first_block = block_idx;
    publish.publishedRevSide(node_buffer).block_count = 1;
    publish.setPublishedRevDegree(node_buffer, @as(u22, @intCast(1)));
    try publish.syncToPublished(graph, destination_idx);
}

fn publishReverseSourcesForForwardRange(graph: *graph_mod.Graph, source_idx: u32, first_destination: u32, count: u7) !void {
    for (0..count) |offset| {
        try publishSingleReverseSource(graph, first_destination + @as(u32, @intCast(offset)), source_idx);
    }
}

fn publishRepairCandidate(graph: *graph_mod.Graph, node: graph_mod.NodeId) !struct { first_block: u32, second_block: u32 } {
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(graph, first_block, 1, 20);
    fillForwardBlock(graph, second_block, 21, 20);
    try publishReverseSourcesForForwardRange(graph, node.index, 1, 20);
    try publishReverseSourcesForForwardRange(graph, node.index, 21, 20);

    const node_buffer = try graph.nodeAt(node);
    publish.clearPublishedSides(node_buffer);
    publish.publishedFwdSide(node_buffer).first_block = first_block;
    publish.publishedFwdSide(node_buffer).block_count = 2;
    publish.setPublishedFwdDegree(node_buffer, @as(u22, @intCast(40)));
    try publish.syncToPublished(graph, node.index);
    graph.graph.edge_count.store(40, .release);

    return .{ .first_block = first_block, .second_block = second_block };
}

test "oom repair: repairNode induced allocation failures do not publish partial adjacency" {
    for (0..8) |failure_offset| {
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
        var graph = try graph_mod.Graph.init(failing_allocator.allocator());
        defer graph.deinit();

        try addNodeCount(&graph, 50);
        const node = graph_mod.NodeId{ .index = 0 };
        const original = try publishRepairCandidate(&graph, node);
        failing_allocator.fail_index = failing_allocator.alloc_index + failure_offset;
        const result = repair.repairNodeSide(&graph.graph, node, .fwd);

        if (result) |compacted| {
            try testing.expectEqual(@as(usize, 1), compacted);
            try testing.expectEqual(@as(usize, 40), try graph.outDegree(node));
            try graph.validate();
        } else |err| switch (err) {
            error.OutOfMemory => {
                const adjacency = try graph.publishedNodeAdj(node);
                try testing.expectEqual(original.first_block, adjacency.first_block_fwd);
                try testing.expectEqual(@as(u16, 2), adjacency.block_count_fwd);
                try testing.expectEqual(@as(u64, 40), graph.edgeCount());
            },
            else => return err,
        }
    }
}
