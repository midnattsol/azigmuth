const std = @import("std");
const graphz = @import("graphz");
const snapshot_support = @import("snapshot_support.zig");

const testing = std.testing;
const SpinBudget: usize = 200_000_000;

fn spinFor(spin_count: *usize, max: usize) bool {
    if (spin_count.* >= max) return false;
    spin_count.* += 1;
    std.atomic.spinLoopHint();
    return true;
}

const ReaderCtx = struct {
    graph: *graphz.Graph,
    node: graphz.NodeId,
    stop: *std.atomic.Value(bool),
    reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn readerLoop(ctx: *ReaderCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        var iter = snapshot_support.neighbors(ctx.graph, ctx.node, std.heap.page_allocator) catch continue;
        defer iter.deinit();
        const materialized = iter.materialize(std.heap.page_allocator) catch continue;
        defer std.heap.page_allocator.free(materialized);
        _ = ctx.reads.fetchAdd(1, .monotonic);
    }
}

const RemoveNodeCtx = struct {
    graph: *graphz.Graph,
    target: graphz.NodeId,
    stop: *std.atomic.Value(bool),
    start_gate: *std.atomic.Value(u32),
    successes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn removeNodeInLoop(ctx: *RemoveNodeCtx) void {
    _ = ctx.start_gate.fetchSub(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) > 0) {
        std.atomic.spinLoopHint();
    }

    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        if (ctx.graph.removeNode(ctx.target)) |_| {
            _ = ctx.successes.fetchAdd(1, .monotonic);
            return;
        } else |_| {}
    }
}

const ForwardMutatorCtx = struct {
    graph: *graphz.Graph,
    predecessor: graphz.NodeId,
    other_node: graphz.NodeId,
    stop: *std.atomic.Value(bool),
    start_gate: *std.atomic.Value(u32),
    mutations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn forwardMutatorInLoop(ctx: *ForwardMutatorCtx) void {
    _ = ctx.start_gate.fetchSub(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) > 0) {
        std.atomic.spinLoopHint();
    }

    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        ctx.graph.addEdge(ctx.predecessor, ctx.other_node, 0, .{}) catch continue;
        _ = ctx.graph.removeEdge(ctx.predecessor, ctx.other_node) catch {};
        _ = ctx.mutations.fetchAdd(1, .monotonic);
    }
}

test "contract: removeNode tolerates unrelated predecessor forward mutation" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, target, 0, .{});

    const other_node = try graph.addNode();

    var stop = std.atomic.Value(bool).init(false);
    var start_gate = std.atomic.Value(u32).init(2);

    var rm_ctx = RemoveNodeCtx{
        .graph = graph,
        .target = target,
        .stop = &stop,
        .start_gate = &start_gate,
    };
    var mut_ctx = ForwardMutatorCtx{
        .graph = graph,
        .predecessor = predecessor,
        .other_node = other_node,
        .stop = &stop,
        .start_gate = &start_gate,
    };

    var rm_thread = try std.Thread.spawn(.{}, removeNodeInLoop, .{&rm_ctx});
    var mutator_thread = try std.Thread.spawn(.{}, forwardMutatorInLoop, .{&mut_ctx});

    var wait: usize = 0;
    while ((rm_ctx.successes.load(.acquire) == 0 or mut_ctx.mutations.load(.acquire) == 0) and wait < SpinBudget) : (wait += 1) {
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);

    rm_thread.join();
    mutator_thread.join();

    try testing.expectEqual(@as(u64, 1), rm_ctx.successes.load(.acquire));
    try testing.expect(mut_ctx.mutations.load(.acquire) > 0);

    var snapshot = try graph.snapshot(testing.allocator);
    defer snapshot.deinit();
    const violations = try snapshot.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "contract: concurrent readers on disjoint nodes are lock-free" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    const node_a = try graph.addNode();
    const node_b = try graph.addNode();
    try graph.addEdge(node_a, node_b, 0, .{});
    const extra = try graph.addNode();
    try graph.addEdge(node_b, extra, 0, .{});

    var stop = std.atomic.Value(bool).init(false);

    var ctx_one = ReaderCtx{
        .graph = graph,
        .node = node_a,
        .stop = &stop,
    };
    var ctx_two = ReaderCtx{
        .graph = graph,
        .node = node_b,
        .stop = &stop,
    };

    var thread_one = try std.Thread.spawn(.{}, readerLoop, .{&ctx_one});
    var thread_two = try std.Thread.spawn(.{}, readerLoop, .{&ctx_two});

    var verify_spin: usize = 0;
    while (verify_spin < 200_000) : (verify_spin += 1) {
        if (ctx_one.reads.load(.acquire) > 0 and ctx_two.reads.load(.acquire) > 0) break;
        std.atomic.spinLoopHint();
    }

    stop.store(true, .release);
    thread_one.join();
    thread_two.join();

    try testing.expect(ctx_one.reads.load(.acquire) > 0);
    try testing.expect(ctx_two.reads.load(.acquire) > 0);
    try graph.validate();
}

test "contract: validate() tolerates concurrent multigraph addEdgeWithId/removeEdgeWithId" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.initWithOptions(allocator, .{ .multigraph = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(source, target, 0, .{});

    const other = try graph.addNode();

    var stop = std.atomic.Value(bool).init(false);
    // Only the mutator participates in the start gate; validator can begin immediately.
    var start_gate = std.atomic.Value(u32).init(1);

    var mut_ctx = ForwardMutatorCtx{
        .graph = graph,
        .predecessor = source,
        .other_node = other,
        .stop = &stop,
        .start_gate = &start_gate,
    };
    var val_ctx = ReaderCtx{
        .graph = graph,
        .node = source,
        .stop = &stop,
        .reads = std.atomic.Value(u64).init(0),
    };

    var val_thread = try std.Thread.spawn(.{}, validatorInLoop, .{&val_ctx});
    var mut_thread = try std.Thread.spawn(.{}, forwardMutatorInLoop, .{&mut_ctx});

    var verify_spin: usize = 0;
    while (verify_spin < SpinBudget) : (verify_spin += 1) {
        if (val_ctx.reads.load(.acquire) > 0 and mut_ctx.mutations.load(.acquire) > 0) break;
        std.atomic.spinLoopHint();
    }
    stop.store(true, .release);

    val_thread.join();
    mut_thread.join();

    try testing.expect(val_ctx.reads.load(.acquire) > 0);
    try testing.expect(mut_ctx.mutations.load(.acquire) > 0);
    try graph.validate();
}

fn validatorInLoop(ctx: *ReaderCtx) void {
    var spin: usize = 0;
    while (!ctx.stop.load(.acquire) and spinFor(&spin, SpinBudget)) {
        ctx.graph.validate() catch continue;
        _ = ctx.reads.fetchAdd(1, .monotonic);
    }
}
