const std = @import("std");
const graph_mod = @import("graph_mod");
const bfs_mod = graph_mod.bfs_mod;
const dfs_mod = graph_mod.dfs_mod;
const cycle_mod = graph_mod.cycle_mod;

const testing = std.testing;

const StartFlag = std.atomic.Value(bool);

const AddChildrenCtx = struct {
    graph: *graph_mod.Graph,
    parent: graph_mod.NodeId,
    start: *StartFlag,
    stop: *StartFlag,
    traversal_active: *StartFlag,
    created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    created_during_traversal: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn addChildrenLoop(ctx: *AddChildrenCtx) void {
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

    var added: usize = 0;
    while (!ctx.stop.load(.acquire) and added < 256) {
        const child = ctx.graph.addNode() catch continue;
        ctx.graph.addEdge(ctx.parent, child, 0, 0) catch continue;
        _ = ctx.created.fetchAdd(1, .monotonic);
        if (ctx.traversal_active.load(.acquire)) {
            _ = ctx.created_during_traversal.fetchAdd(1, .monotonic);
        }
        added += 1;
        std.atomic.spinLoopHint();
    }
}

const RemoveNodeOnceCtx = struct {
    graph: *graph_mod.Graph,
    node: graph_mod.NodeId,
    start: *StartFlag,
    traversal_active: *StartFlag,
    attempted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    attempted_during_traversal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn removeNodeOnce(ctx: *RemoveNodeOnceCtx) void {
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
    while (!ctx.traversal_active.load(.acquire)) std.atomic.spinLoopHint();
    _ = ctx.graph.removeNode(ctx.node) catch {};
    ctx.attempted_during_traversal.store(ctx.traversal_active.load(.acquire), .release);
    ctx.attempted.store(true, .release);
}

fn buildWideRootGraph(graph: *graph_mod.Graph, child_count: usize) !struct {
    root: graph_mod.NodeId,
    first_child: graph_mod.NodeId,
    last_child: graph_mod.NodeId,
} {
    const root = try graph.addNode();
    var first_child: ?graph_mod.NodeId = null;
    var last_child: graph_mod.NodeId = undefined;
    for (0..child_count) |_| {
        const child = try graph.addNode();
        if (first_child == null) first_child = child;
        last_child = child;
        try graph.addEdge(root, child, 0, 0);
    }
    return .{ .root = root, .first_child = first_child.?, .last_child = last_child };
}

test "algorithms concurrent: bfs tolerates addNode/addEdge while traversing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var stop = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    var ctx = AddChildrenCtx{ .graph = &graph, .parent = setup.last_child, .start = &start, .stop = &stop, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, addChildrenLoop, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    var wait_for_mutation: usize = 0;
    while (ctx.created.load(.acquire) == 0 and wait_for_mutation < 5_000_000) : (wait_for_mutation += 1) {
        std.atomic.spinLoopHint();
    }
    traversal_active.store(true, .release);
    const order = try bfs_mod.bfs(&graph.graph, setup.root, testing.allocator);
    traversal_active.store(false, .release);
    defer testing.allocator.free(order);
    stop.store(true, .release);

    try testing.expectEqual(setup.root.index, order[0].index);
    try testing.expect(ctx.created_during_traversal.load(.acquire) > 0);
}

test "algorithms concurrent: dfs tolerates addNode/addEdge while traversing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var stop = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    // DFS pops the most recently pushed node first, so child 1 is expanded late.
    var ctx = AddChildrenCtx{ .graph = &graph, .parent = setup.first_child, .start = &start, .stop = &stop, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, addChildrenLoop, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    var wait_for_mutation: usize = 0;
    while (ctx.created.load(.acquire) == 0 and wait_for_mutation < 5_000_000) : (wait_for_mutation += 1) {
        std.atomic.spinLoopHint();
    }
    traversal_active.store(true, .release);
    const order = try dfs_mod.dfs(&graph.graph, setup.root, testing.allocator);
    traversal_active.store(false, .release);
    defer testing.allocator.free(order);
    stop.store(true, .release);

    try testing.expectEqual(setup.root.index, order[0].index);
    try testing.expect(ctx.created_during_traversal.load(.acquire) > 0);
}

test "algorithms concurrent: cycle tolerates addNode/addEdge while traversing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var stop = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    var ctx = AddChildrenCtx{ .graph = &graph, .parent = setup.first_child, .start = &start, .stop = &stop, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, addChildrenLoop, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    var wait_for_mutation: usize = 0;
    while (ctx.created.load(.acquire) == 0 and wait_for_mutation < 5_000_000) : (wait_for_mutation += 1) {
        std.atomic.spinLoopHint();
    }
    traversal_active.store(true, .release);
    const has_cycle = try cycle_mod.hasCycle(&graph.graph, testing.allocator);
    traversal_active.store(false, .release);
    stop.store(true, .release);

    try testing.expect(!has_cycle);
    try testing.expect(ctx.created_during_traversal.load(.acquire) > 0);
}

test "algorithms concurrent: bfs tolerates node removed before expansion" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    var ctx = RemoveNodeOnceCtx{ .graph = &graph, .node = setup.last_child, .start = &start, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, removeNodeOnce, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    traversal_active.store(true, .release);
    const order = try bfs_mod.bfs(&graph.graph, setup.root, testing.allocator);
    traversal_active.store(false, .release);
    defer testing.allocator.free(order);

    while (!ctx.attempted.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(ctx.attempted_during_traversal.load(.acquire));
    try testing.expect(order.len >= 1);
}

test "algorithms concurrent: dfs tolerates node removed before expansion" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    var ctx = RemoveNodeOnceCtx{ .graph = &graph, .node = setup.first_child, .start = &start, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, removeNodeOnce, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    traversal_active.store(true, .release);
    const order = try dfs_mod.dfs(&graph.graph, setup.root, testing.allocator);
    traversal_active.store(false, .release);
    defer testing.allocator.free(order);

    while (!ctx.attempted.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(ctx.attempted_during_traversal.load(.acquire));
    try testing.expect(order.len >= 1);
}

test "algorithms concurrent: cycle tolerates node removed during traversal" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const setup = try buildWideRootGraph(&graph, 5000);
    var start = StartFlag.init(false);
    var traversal_active = StartFlag.init(false);
    var ctx = RemoveNodeOnceCtx{ .graph = &graph, .node = setup.first_child, .start = &start, .traversal_active = &traversal_active };
    const thread = try std.Thread.spawn(.{}, removeNodeOnce, .{&ctx});
    defer thread.join();

    start.store(true, .release);
    traversal_active.store(true, .release);
    const has_cycle = try cycle_mod.hasCycle(&graph.graph, testing.allocator);
    traversal_active.store(false, .release);

    while (!ctx.attempted.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(ctx.attempted_during_traversal.load(.acquire));
    try testing.expect(!has_cycle);
}
