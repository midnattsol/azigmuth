const std = @import("std");
const test_internals = @import("test_internals");

const graph_mod = test_internals.graph;
const testing = std.testing;

test "lifecycle: readerEnter increments active_readers, readerExit decrements" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const token = graph.readerEnter();
    try testing.expect(graph.graph.active_readers.load(.acquire) > 0);

    graph.readerExit(token);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "lifecycle: iterator deinit releases the reader token" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, 0);

    const before = graph.graph.active_readers.load(.acquire);

    var iterator = try graph.neighbors(source);
    try testing.expect(graph.graph.active_readers.load(.acquire) > before);

    _ = iterator.next();
    iterator.deinit();
    try testing.expectEqual(before, graph.graph.active_readers.load(.acquire));
}

test "lifecycle: multiple readerEnter calls are balanced by matching readerExit" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const t1 = graph.readerEnter();
    const t2 = graph.readerEnter();
    const t3 = graph.readerEnter();

    try testing.expect(graph.graph.active_readers.load(.acquire) >= 3);

    graph.readerExit(t3);
    graph.readerExit(t2);
    graph.readerExit(t1);

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "lifecycle: readerExit clears the reader slot leaving active count at zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const token = graph.readerEnter();
    try testing.expect(graph.graph.active_readers.load(.acquire) > 0);
    graph.readerExit(token);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}
