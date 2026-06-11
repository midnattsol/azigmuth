const std = @import("std");
const azigmuth = @import("azigmuth");

const testing = std.testing;

test "read session: point reads without whole-graph capture" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [8]azigmuth.NodeId = undefined;
    for (0..destinations.len) |i| {
        destinations[i] = try graph.addNode();
        try graph.addEdge(source, destinations[i], 0, .{});
    }

    var session = try graph.readSession(testing.allocator);
    defer session.deinit();

    try testing.expectEqual(@as(usize, 9), session.nodeCount());
    try testing.expectEqual(@as(usize, 8), try session.outDegree(source));
    try testing.expectEqual(@as(usize, 1), try session.inDegree(destinations[0]));

    var it = try session.neighbors(source);
    defer it.deinit();
    var seen: usize = 0;
    while (it.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 8), seen);
}

test "read session: keeps deinitChecked busy until closed" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    var session = try graph.readSession(testing.allocator);

    try testing.expectError(error.GraphBusy, graph.deinitChecked());

    session.deinit();
    // The graph stays usable after the failed checked teardown.
    _ = try graph.addNode();
    try graph.validate();
}

test "read session: observes mutations published after it opened" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();

    var session = try graph.readSession(testing.allocator);
    defer session.deinit();
    try testing.expectEqual(@as(usize, 0), try session.outDegree(source));

    try graph.addEdge(source, destination, 0, .{});
    // A session is a live view, not a snapshot: new published state is visible.
    try testing.expectEqual(@as(usize, 1), try session.outDegree(source));
}

test "read session: invalid node surfaces InvalidNode" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    var session = try graph.readSession(testing.allocator);
    defer session.deinit();

    try testing.expectError(error.InvalidNode, session.outDegree(.{ .index = 999 }));
    try testing.expectError(error.InvalidNode, session.neighbors(.{ .index = 999 }));
}
