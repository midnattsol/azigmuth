const std = @import("std");
const graph_mod = @import("graph_mod");

const Graph = graph_mod.Graph;
const testing = std.testing;

test "graph readers: neighbor iterator deinit releases RCU reader count" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    {
        var iterator = try graph.neighbors(source);
        try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));
        _ = iterator.next();
        iterator.deinit();
    }

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "graph readers: reader guard remains active until iterator deinit" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const start_readers = graph.graph.active_readers.load(.acquire);
    var iterator = try graph.neighbors(source);

    const after_readers = graph.graph.active_readers.load(.acquire);
    try testing.expect(after_readers > start_readers);
    try testing.expectEqual(@as(u32, 1), graph.graph.active_readers.load(.acquire));

    iterator.deinit();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}

test "graph readers: validate APIs release reader guards" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
    try graph.validate();
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));

    const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
    try testing.expectEqual(@as(u32, 0), graph.graph.active_readers.load(.acquire));
}
