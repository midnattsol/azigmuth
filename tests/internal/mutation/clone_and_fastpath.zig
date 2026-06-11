//! Coverage for the removal-rebuild block cloners and the forward fast-path
//! gate. cloneForwardBlock/cloneReverseBlock must copy the live-count sidecar
//! along with the block payload — missing that copy was a real COW corruption
//! bug, so it gets a direct regression test here.

const std = @import("std");
const graph_mod = @import("graph_mod");
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const common = graph_mod.mutation_common_mod;
const rebuild_common = graph_mod.remove_rebuild_common_mod;
const fast_path = graph_mod.remove_fast_path_mod;

const testing = std.testing;

test "cloneForwardBlock copies payload and live-count sidecar" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [6]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const blk = try graph.allocBlockFwd();
    const source_block = page_ops.edgeBlockAt(&graph.graph, blk, .fwd);
    for (0..5) |slot| {
        source_block.destinations[slot] = nodes[slot].index;
        source_block.relations[slot] = @intCast(slot);
        source_block.flags[slot] = 0;
    }
    page_ops.setBlockLiveCount(&graph.graph, blk, .fwd, 5);

    var scratch = common.MutationScratch{};
    defer scratch.deinit(testing.allocator);

    const cloned = try rebuild_common.cloneForwardBlock(&graph.graph, &scratch, blk);
    try testing.expect(cloned != blk);

    const cloned_block = page_ops.edgeBlockAtConst(&graph.graph, cloned, .fwd);
    for (0..5) |slot| {
        try testing.expectEqual(nodes[slot].index, cloned_block.destinations[slot]);
        try testing.expectEqual(@as(u16, @intCast(slot)), cloned_block.relations[slot]);
    }
    try testing.expectEqual(@as(u7, 5), page_ops.blockLiveCount(&graph.graph, cloned, .fwd));
}

test "cloneReverseBlock copies payload and live-count sidecar" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const blk = try graph.allocBlockRev();
    const source_block = page_ops.edgeBlockAt(&graph.graph, blk, .rev);
    for (0..3) |slot| source_block.sources[slot] = nodes[slot].index;
    page_ops.setBlockLiveCount(&graph.graph, blk, .rev, 3);

    var scratch = common.MutationScratch{};
    defer scratch.deinit(testing.allocator);

    const cloned = try rebuild_common.cloneReverseBlock(&graph.graph, &scratch, blk);
    try testing.expect(cloned != blk);

    const cloned_block = page_ops.edgeBlockAtConst(&graph.graph, cloned, .rev);
    for (0..3) |slot| {
        try testing.expectEqual(nodes[slot].index, cloned_block.sources[slot]);
    }
    try testing.expectEqual(@as(u7, 3), page_ops.blockLiveCount(&graph.graph, cloned, .rev));
}

test "ensureForwardFastPathAllowedIfBlock: tiny sides always pass" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    const ref = try graph.nodeAt(a);
    const fwd = ref.publishedFwd();
    // Tiny storage never needs the block fast-path check, even without a hit.
    try fast_path.ensureForwardFastPathAllowedIfBlock(&graph.graph, &fwd, null);
}

test "ensureForwardFastPathAllowedIfBlock: block sides demand a located slot and tail locality" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const blk0 = try graph.allocBlockFwd();
    const b0 = page_ops.edgeBlockAt(&graph.graph, blk0, .fwd);
    b0.destinations[0] = nodes[0].index;
    b0.relations[0] = 0;
    b0.flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, blk0, .fwd, 1);

    const blk1 = try graph.allocBlockFwd();
    const b1 = page_ops.edgeBlockAt(&graph.graph, blk1, .fwd);
    b1.destinations[0] = nodes[1].index;
    b1.relations[0] = 0;
    b1.flags[0] = 0;
    page_ops.setBlockLiveCount(&graph.graph, blk1, .fwd, 1);

    const single = types.SideAdj{ .first_block = blk0, .block_count = 1, .group_count = 0, .first_group = 0 };
    // A block side without a located slot is corruption.
    try testing.expectError(error.CorruptGraph, fast_path.ensureForwardFastPathAllowedIfBlock(&graph.graph, &single, null));
    // Single-block sides allow removal anywhere.
    try fast_path.ensureForwardFastPathAllowedIfBlock(&graph.graph, &single, .{ .block_idx = blk0, .slot = 0 });

    const double = types.SideAdj{ .first_block = blk0, .block_count = 2, .group_count = 0, .first_group = 0 };
    // Multi-block sides only allow the fast path in the tail block.
    try testing.expectError(error.RepairRequired, fast_path.ensureForwardFastPathAllowedIfBlock(&graph.graph, &double, .{ .block_idx = blk0, .slot = 0 }));
    try fast_path.ensureForwardFastPathAllowedIfBlock(&graph.graph, &double, .{ .block_idx = blk1, .slot = 0 });
}
