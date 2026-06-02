const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;

const testing = std.testing;

test "rcu: reclaimRetired blocks when all reader slots are saturated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    for (&graph.graph.reader_epochs) |*slot| {
        slot.store(1, .release);
    }

    graph.reclaimRetired();
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    for (&graph.graph.reader_epochs) |*slot| {
        slot.store(0, .release);
    }

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    try testing.expectEqual(@as(usize, 0), graph.graph.retired_blocks_fwd.items.len);
}

test "rcu: reclaimRetired blocks when overflow reader present even with free slots" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    _ = graph.graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);

    graph.reclaimRetired();
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    _ = graph.graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    try testing.expectEqual(@as(usize, 0), graph.graph.retired_blocks_fwd.items.len);
}

test "rcu: mixed slot + overflow readers block reclamation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    graph.graph.reader_epochs[0].store(1, .release);
    _ = graph.graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);

    graph.reclaimRetired();
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    _ = graph.graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    graph.reclaimRetired();
    try testing.expect(graph.graph.retired_blocks_fwd.items.len > 0);

    graph.graph.reader_epochs[0].store(0, .release);
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    try testing.expectEqual(@as(usize, 0), graph.graph.retired_blocks_fwd.items.len);
}
