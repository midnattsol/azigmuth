const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "rcu: reclaimRetired blocks when all reader slots are saturated" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    for (&graph.graph.reader_epochs) |*slot| {
        slot.store(1, .release);
    }

    graph.reclaimRetired();
    for (&graph.graph.reader_epochs) |*slot| {
        slot.store(0, .release);
    }

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
}

test "rcu: reclaimRetired blocks when overflow reader present even with free slots" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    _ = graph.graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);

    graph.reclaimRetired();
    _ = graph.graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
}

test "rcu: mixed slot + overflow readers block reclamation" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const block = try graph.allocBlockFwd();
    try graph.retireBlockFwd(block);
    graph.graph.reader_epochs[0].store(1, .release);
    _ = graph.graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);

    graph.reclaimRetired();
    _ = graph.graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    graph.reclaimRetired();
    graph.graph.reader_epochs[0].store(0, .release);
    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
}
