const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

const ProducerCtx = struct {
    graph: *graph_mod.Graph,
    nodes_per_producer: usize,
    produced: std.ArrayList(u32) = .empty,
};

fn producerLoop(ctx: *ProducerCtx) void {
    var produced: usize = 0;
    while (produced < ctx.nodes_per_producer) {
        if (ctx.graph.addNode()) |node| {
            ctx.produced.append(ctx.graph.graph.allocator, node.index) catch return;
            produced += 1;
        } else |_| {
            // Retry on transient OOM under contention.
        }
    }
}

test "addNode: 8 producers in parallel produce unique, sequential NodeIds" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const producer_count: usize = 8;
    const per_producer: usize = 100;
    const expected_total: usize = producer_count * per_producer;

    var ctxs: [producer_count]ProducerCtx = undefined;
    var threads: [producer_count]std.Thread = undefined;
    for (0..producer_count) |producer_idx| {
        ctxs[producer_idx] = .{
            .graph = &graph,
            .nodes_per_producer = per_producer,
        };
        threads[producer_idx] = try std.Thread.spawn(.{}, producerLoop, .{&ctxs[producer_idx]});
    }

    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(usize, expected_total), graph.nodeCount());

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, expected_total + 16);
    defer seen.deinit(allocator);

    for (ctxs) |ctx| {
        try testing.expectEqual(per_producer, ctx.produced.items.len);
        for (ctx.produced.items) |index| {
            try testing.expect(!seen.isSet(index));
            seen.set(index);
        }
    }
    try testing.expectEqual(@as(usize, expected_total), seen.count());

    try graph.validate();
}

test "addNode: parallel producers with concurrent edge insertion keep forward/reverse consistent" {
    const allocator = std.heap.page_allocator;
    var graph = try graph_mod.Graph.init(allocator);
    defer graph.deinit();

    const producer_count: usize = 3;
    const per_producer: usize = 50;
    var ctxs: [producer_count]ProducerCtx = undefined;
    var threads: [producer_count + 1]std.Thread = undefined;

    for (0..producer_count) |producer_idx| {
        ctxs[producer_idx] = .{ .graph = &graph, .nodes_per_producer = per_producer };
        threads[producer_idx] = try std.Thread.spawn(.{}, producerLoop, .{&ctxs[producer_idx]});
    }

    // Edge-adder thread: periodically picks two random published node indices
    // and tries to add an edge between them, concurrently with addNode producers.
    const AdderCtx = struct {
        graph: *graph_mod.Graph,
        successful_adds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };
    var adder_ctx: AdderCtx = .{ .graph = &graph };
    threads[producer_count] = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *AdderCtx) void {
            var state: u64 = 0xCAFEBABE_DEADBEEF;
            var iterations: usize = 0;
            while (iterations < 300) {
                const n = ctx.graph.graph.publishedNodeCount();
                if (n < 2) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                iterations += 1;
                state = state *% 6364136223846793005 +% 1442695040888963407;
                const src_idx: u32 = @intCast(state % n);
                state = state *% 6364136223846793005 +% 1442695040888963407;
                const dst_idx: u32 = @intCast(state % n);
                if (src_idx != dst_idx) {
                    if (ctx.graph.addEdge(.{ .index = src_idx }, .{ .index = dst_idx }, 0, 0)) {
                        _ = ctx.successful_adds.fetchAdd(1, .monotonic);
                    } else |_| {}
                }
            }
        }
    }.run, .{&adder_ctx});

    for (threads[0..producer_count]) |thread| thread.join();
    threads[producer_count].join();

    try testing.expectEqual(@as(usize, producer_count * per_producer), graph.nodeCount());
    try testing.expect(adder_ctx.successful_adds.load(.acquire) > 0);

    const violations = try graph.debugValidate(.{ .allocator = allocator });
    defer allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);

    var total_edges: u64 = 0;
    for (0..graph.nodeCount()) |idx| {
        const node = graph_mod.NodeId{ .index = @intCast(idx) };
        if (graph.hasNode(node)) {
            total_edges += @as(u64, @intCast(try graph.outDegree(node)));
        }
    }
    try testing.expectEqual(total_edges, graph.edgeCount());
}
