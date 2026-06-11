const std = @import("std");
const graph_mod = @import("graph_mod");
const types = graph_mod.types_mod;
const page_ops = graph_mod.page_ops_mod;
const publish = @import("publish");

const testing = std.testing;

fn publishedOfTest(graph: *graph_mod.Graph, node: graph_mod.NodeId) *graph_mod.node_published_mod.NodePublished {
    return graph_mod.page_ops_mod.ensureNodePublishedAt(&graph.graph, node) catch @panic("ensure published failed");
}

test "snapshot coherence: publishedAdjFromMeta can return stale side buffers after slot reuse" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    // ---- publish state A: slot 0 = {1 block, block_count=1}
    const b0 = try graph.allocBlockFwd();
    publishedOfTest(&graph, node).fwd[0] = types.SideAdj{
        .first_block = b0,
        .block_count = 1,
        .group_count = 0,
        .first_group = 0,
    };
    var meta0 = node_buffer.loadPublishedMeta();
    meta0.fwd_index = 0;
    node_buffer.storePublishedMeta(meta0);

    const snapshot_a = graph.nodeRefAny(node).publishedAdj();
    try testing.expectEqual(@as(u32, b0), snapshot_a.first_block_fwd);
    try testing.expectEqual(@as(u16, 1), snapshot_a.block_count_fwd);

    // ---- publish state B: flip to slot 1 = {2 blocks}
    const b1 = try graph.allocBlockFwd();
    publishedOfTest(&graph, node).fwd[1] = types.SideAdj{
        .first_block = b1,
        .block_count = 1,
        .group_count = 0,
        .first_group = 0,
    };
    var meta1 = meta0;
    meta1.fwd_index = 1;
    node_buffer.storePublishedMeta(meta1);

    // ---- publish state C: flip back to slot 0, overwriting old state A
    const b3 = try graph.allocBlockFwd();
    publishedOfTest(&graph, node).fwd[0] = types.SideAdj{
        .first_block = b3,
        .block_count = 3,
        .group_count = 0,
        .first_group = 0,
    };
    var meta2 = meta1;
    meta2.fwd_index = 0;
    node_buffer.storePublishedMeta(meta2);

    // ---- reader that cached meta0 before the flips now reads from
    //      publishedAdjFromMeta(meta0). It gets slot 0 → state C, not A.
    const snapshot_from_meta0 = node_buffer.publishedAdjFromMeta(meta0);
    try testing.expectEqual(@as(u32, b3), snapshot_from_meta0.first_block_fwd);
    try testing.expectEqual(@as(u16, 3), snapshot_from_meta0.block_count_fwd);

    // The current published snapshot is C (slot 0).
    const latest = node_buffer.publishedAdj();
    try testing.expectEqual(@as(u32, b3), latest.first_block_fwd);
}

test "snapshot coherence: publishedAdjFromMeta on reverse side can also return stale data" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    const r0 = try graph.allocBlockRev();
    publishedOfTest(&graph, node).rev[0] = types.SideAdj{
        .first_block = r0,
        .block_count = 1,
        .group_count = 0,
        .first_group = 0,
    };
    var meta0 = node_buffer.loadPublishedMeta();
    meta0.rev_index = 0;
    node_buffer.storePublishedMeta(meta0);

    // Publish slot 1
    const r1 = try graph.allocBlockRev();
    publishedOfTest(&graph, node).rev[1] = types.SideAdj{
        .first_block = r1,
        .block_count = 2,
        .group_count = 0,
        .first_group = 0,
    };
    var meta1 = meta0;
    meta1.rev_index = 1;
    node_buffer.storePublishedMeta(meta1);

    // Overwrite slot 0
    const r2 = try graph.allocBlockRev();
    publishedOfTest(&graph, node).rev[0] = types.SideAdj{
        .first_block = r2,
        .block_count = 3,
        .group_count = 0,
        .first_group = 0,
    };
    var meta2 = meta1;
    meta2.rev_index = 0;
    node_buffer.storePublishedMeta(meta2);

    // meta0 (rev_index=0) now reads slot 0 → state with r2 = 3, not r0 = 1
    const snapshot_from_meta0 = node_buffer.publishedAdjFromMeta(meta0);
    try testing.expectEqual(@as(u32, r2), snapshot_from_meta0.first_block_rev);
    try testing.expectEqual(@as(u16, 3), snapshot_from_meta0.block_count_rev);
}

test "snapshot coherence: isNodeRemoved via publishedAdj().flags.removed can disagree with loadPublishedMeta().removed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    // Start with removed=false, slot 0 published.
    var meta0 = node_buffer.loadPublishedMeta();
    meta0.removed = false;
    meta0.fwd_index = 0;
    node_buffer.storePublishedMeta(meta0);

    // Flip to slot 1, still removed=false.
    var meta1 = meta0;
    meta1.fwd_index = 1;
    node_buffer.storePublishedMeta(meta1);

    // Overwrite slot 0 with removed=true, publish.
    var meta2 = meta1;
    meta2.fwd_index = 0;
    meta2.removed = true;
    node_buffer.storePublishedMeta(meta2);

    try testing.expect(meta2.removed);
    try testing.expect(node_buffer.loadPublishedMeta().removed);

    // publishedAdj() rebuilds flags from side buffers → carries meta2.flags() = removed=true.
    // This is correct — it reflects the latest published state.
    try testing.expect(node_buffer.publishedAdj().flags.removed);

    // But publishedAdjFromMeta(meta0) would carry meta0.flags() = removed=false.
    // The flags field in NodeAdj is set from meta.flags(), which is stable per-meta.
    // The side-buffer issue is separate (block indices can be stale).
    // Flags come from meta.flags() directly, so they stay consistent with the meta snapshot.
    const snapshot_from_meta0 = node_buffer.publishedAdjFromMeta(meta0);
    try testing.expect(!snapshot_from_meta0.flags.removed);
}

test "snapshot coherence: mixed fwd/rev slot reuse corrupts both sides simultaneously" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const node_buffer = try graph.nodeAt(node);

    // State A: fwd=0 rev=0, side buffers at originals
    const fwd_a = try graph.allocBlockFwd();
    const rev_a = try graph.allocBlockRev();
    publishedOfTest(&graph, node).fwd[0] = types.SideAdj{ .first_block = fwd_a, .block_count = 1, .group_count = 0, .first_group = 0 };
    publishedOfTest(&graph, node).rev[0] = types.SideAdj{ .first_block = rev_a, .block_count = 1, .group_count = 0, .first_group = 0 };
    var meta0 = node_buffer.loadPublishedMeta();
    meta0.fwd_index = 0;
    meta0.rev_index = 0;
    node_buffer.storePublishedMeta(meta0);

    // Flip both independently: fwd→1, rev still 0
    var meta1 = meta0;
    meta1.fwd_index = 1;
    node_buffer.storePublishedMeta(meta1);

    // After just flipping fwd, slot 0 for fwd is now inactive but still holds A.
    // The reverse side has NOT flipped, so slot 0 for rev is still active.

    // Now flip both: fwd→0, rev→1. This reuses fwd slot 0 which is stale.
    const fwd_b = try graph.allocBlockFwd();
    const rev_b = try graph.allocBlockRev();
    publishedOfTest(&graph, node).fwd[0] = types.SideAdj{ .first_block = fwd_b, .block_count = 2, .group_count = 0, .first_group = 0 };
    publishedOfTest(&graph, node).rev[1] = types.SideAdj{ .first_block = rev_b, .block_count = 2, .group_count = 0, .first_group = 0 };
    var meta2 = meta1;
    meta2.fwd_index = 0;
    meta2.rev_index = 1;
    node_buffer.storePublishedMeta(meta2);

    // A reader with cached meta0 (fwd=0 rev=0) now reads:
    //  - fwd slot 0 = fwd_b (overwritten by subsequent publish)
    //  - rev slot 0 = rev_a (never overwritten, still correct for meta0)
    const snapshot = node_buffer.publishedAdjFromMeta(meta0);
    try testing.expectEqual(@as(u32, fwd_b), snapshot.first_block_fwd);
    try testing.expectEqual(@as(u32, rev_a), snapshot.first_block_rev);

    // The reader sees a MIXED snapshot: forward from state C, reverse from state A.
    // This violates "always observe a complete NodeAdj snapshot — old or new, never a partial node update".
}
