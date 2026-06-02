const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const constants = test_internals.constants;
const page_ops = test_internals.page_ops;
const repair = test_internals.repair;
const types = test_internals.types;
const adjacency_mod = test_internals.adjacency;

const testing = std.testing;

fn addNodeCount(graph: *graph_mod.Graph, count: usize) !void {
    for (0..count) |_| {
        _ = try graph.addNode();
    }
}

fn fillForwardBlock(graph: *graph_mod.Graph, block_index: u32, first_destination: u32, count: u7) void {
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .fwd);
    for (0..count) |edge_index| {
        block.edges[edge_index] = .{ .destination = first_destination + @as(u32, @intCast(edge_index)), .relation = 0, .flags = @bitCast(@as(u16, 0)) };
    }
    block.mask = constants.denseMask(count);
}

fn publishSingleReverseSource(graph: *graph_mod.Graph, destination_index: u32, source_index: u32) !void {
    const block_index = try graph.allocBlockRev();
    var block = page_ops.edgeBlockAt(&graph.graph, block_index, .rev);
    block.sources[0] = source_index;
    block.mask = constants.denseMask(1);

    var node_buffer = try graph.nodeAt(.{ .index = destination_index });
    node_buffer.adj_buffers[0].first_block_rev = block_index;
    node_buffer.adj_buffers[0].block_count_rev = 1;
    node_buffer.degree_rev = 1;
    node_buffer.storePublishedAdjIndex(0);
}

fn publishReverseSourcesForForwardRange(graph: *graph_mod.Graph, source_index: u32, first_destination: u32, count: u7) !void {
    for (0..count) |offset| {
        try publishSingleReverseSource(graph, first_destination + @as(u32, @intCast(offset)), source_index);
    }
}

fn publishRepairCandidate(graph: *graph_mod.Graph, node: graph_mod.NodeId) !struct { first_block: u32, second_block: u32 } {
    const first_block = try graph.allocBlockFwd();
    const second_block = try graph.allocBlockFwd();
    fillForwardBlock(graph, first_block, 1, 20);
    fillForwardBlock(graph, second_block, 21, 20);
    try publishReverseSourcesForForwardRange(graph, node.index, 1, 20);
    try publishReverseSourcesForForwardRange(graph, node.index, 21, 20);

    var node_buffer = try graph.nodeAt(node);
    node_buffer.adj_buffers[0] = std.mem.zeroes(types.NodeAdj);
    node_buffer.adj_buffers[0].first_block_fwd = first_block;
    node_buffer.adj_buffers[0].block_count_fwd = 2;
    node_buffer.degree_fwd = 40;
    node_buffer.storePublishedAdjIndex(0);
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
        const retired_before = graph.graph.retired_blocks_fwd.items.len;

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
                try testing.expectEqual(retired_before, graph.graph.retired_blocks_fwd.items.len);
                try testing.expectEqual(@as(u64, 40), graph.edgeCount());
            },
            else => return err,
        }
    }
}

test "oom repair: appendGroupToAdj failure while creating prefix group leaves adjacency unchanged" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var graph = try graph_mod.Graph.init(failing_allocator.allocator());
    defer graph.deinit();

    const first_block = try graph.allocBlockFwd();
    const new_block = try graph.allocBlockFwd();
    for (0..constants.EDGE_GROUPS_PER_PAGE - 1) |_| {
        _ = try graph.allocGroup();
    }

    var adjacency = std.mem.zeroes(types.NodeAdj);
    adjacency.first_block_fwd = first_block;
    adjacency.block_count_fwd = 1;

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, adjacency_mod.appendGroupToAdj(&graph.graph, &adjacency, new_block, .fwd));
    try testing.expectEqual(@as(u16, 0), adjacency.group_count_fwd);
    try testing.expectEqual(@as(u32, 0), adjacency.first_group_fwd);
    try testing.expectEqual(@as(u16, 1), adjacency.block_count_fwd);
}
