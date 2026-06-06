const std = @import("std");
const graphz = @import("graphz");

const testing = std.testing;

// ── Lifecycle ──────────────────────────────────────────────────────────────

test "contract: deinitChecked fails with active iterator and handle stays usable" {
    var graph = try graphz.Graph.init(testing.allocator);
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    defer iter.deinit();

    try testing.expectError(error.GraphBusy, graph.deinitChecked());
    iter.deinit();
    graph.deinit();
}

test "contract: deinitChecked succeeds on clean graph and consumes handle" {
    var graph = try graphz.Graph.init(testing.allocator);
    try graph.deinitChecked();
}

// ── Iterator ───────────────────────────────────────────────────────────────

test "contract: materialize with defer deinit is safe" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..3) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 3), neighbors.len);
}

test "contract: materialize then deinit does not double-free" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    iter.deinit();
}

test "contract: next after materialize returns null" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 1), neighbors.len);
    try testing.expect(iter.next() == null);
    iter.deinit();
}

test "contract: neighbors returns by value (no alloc on creation)" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const neighbor = iter.next().?;
    try testing.expectEqual(destination.index, neighbor.index);
}

test "contract: empty iterator materialize returns empty slice" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();

    var iter = try graph.neighbors(node);
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 0), neighbors.len);
    iter.deinit();
}

test "contract: double deinit on iterator is harmless" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    var iter = try graph.neighbors(source);
    iter.deinit();
    iter.deinit();
}

test "contract: iterator remains usable until owner deinit" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const first_destination = try graph.addNode();
    const second_destination = try graph.addNode();
    try graph.addEdge(source, first_destination, 0, .{});
    try graph.addEdge(source, second_destination, 0, .{});

    var iter = try graph.neighbors(source);
    defer iter.deinit();

    try testing.expect(iter.next() != null);
    const remaining = try iter.materialize(testing.allocator);
    defer testing.allocator.free(remaining);
    try testing.expectEqual(@as(usize, 1), remaining.len);
}

// ── Edge mutations ─────────────────────────────────────────────────────────

test "contract: addEdge with non-zero relation and flags" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 42, .{});
    try graph.validate();

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    try testing.expectEqual(destination.index, iter.next().?.index);
}

test "contract: addEdge self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 1, .{});
    try graph.validate();

    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(node));

    var iter = try graph.neighbors(node);
    defer iter.deinit();
    try testing.expectEqual(node.index, iter.next().?.index);
}

test "contract: addEdge duplicate returns EdgeAlreadyExists" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try testing.expectError(error.EdgeAlreadyExists, graph.addEdge(source, destination, 0, .{}));
}

test "contract: removeEdge returns true when edge exists" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(true, try graph.removeEdge(source, destination));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(source));
    try graph.validate();
}

test "contract: removeEdge returns false when edge does not exist" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(false, try graph.removeEdge(destination, source));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
    try graph.validate();
}

test "contract: removeEdge self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try graph.addEdge(node, node, 0, .{});

    try testing.expectEqual(true, try graph.removeEdge(node, node));
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try testing.expectEqual(@as(usize, 0), try graph.outDegree(node));
    try graph.validate();
}

// ── Node mutations ─────────────────────────────────────────────────────────

test "contract: addNode returns unique IDs" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();
    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expect(first.index != second.index);
    try testing.expect(second.index != third.index);
    try testing.expect(third.index != first.index);
}

test "contract: hasNode returns false for out-of-range index" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    try testing.expectEqual(false, graph.hasNode(.{ .index = 0 }));
    try testing.expectEqual(false, graph.hasNode(.{ .index = 9999 }));
}

test "contract: nodeCount and edgeCount after mutations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    const third = try graph.addNode();
    try graph.addEdge(first, second, 0, .{});
    try graph.addEdge(second, third, 1, .{});

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());
}

// ── removeNode ─────────────────────────────────────────────────────────────

test "contract: removeNode invalidates hasNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    try testing.expect(graph.hasNode(node));
    _ = try graph.removeNode(node);
    try testing.expect(!graph.hasNode(node));
    try graph.validate();
}

test "contract: removeNode clears outgoing edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const extra = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.addEdge(source, extra, 1, .{});

    _ = try graph.removeNode(source);
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var iter = try graph.neighbors(destination);
    defer iter.deinit();
    try testing.expect(iter.next() == null);
}

test "contract: neighbors on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.neighbors(node));
}

test "contract: inNeighbors on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const predecessor = try graph.addNode();
    try graph.addEdge(predecessor, node, 0, .{});
    _ = try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.inNeighbors(node));
}

test "contract: outDegree on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.outDegree(node));
}

test "contract: inDegree on removed node returns InvalidNode" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    _ = try graph.removeNode(node);
    try testing.expectError(error.InvalidNode, graph.inDegree(node));
}

test "contract: removeNode with incoming edges" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor_one = try graph.addNode();
    const predecessor_two = try graph.addNode();
    try graph.addEdge(predecessor_one, target, 0, .{});
    try graph.addEdge(predecessor_two, target, 1, .{});

    _ = try graph.removeNode(target);
    try graph.validate();

    var iter_one = try graph.neighbors(predecessor_one);
    defer iter_one.deinit();
    try testing.expect(iter_one.next() == null);

    var iter_two = try graph.neighbors(predecessor_two);
    defer iter_two.deinit();
    try testing.expect(iter_two.next() == null);
}

test "contract: removeNode self-edge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const neighbor = try graph.addNode();
    try graph.addEdge(node, node, 0, .{});
    try graph.addEdge(node, neighbor, 1, .{});

    _ = try graph.removeNode(node);
    try graph.validate();
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());

    var iter = try graph.neighbors(neighbor);
    defer iter.deinit();
    try testing.expect(iter.next() == null);
}

// ── Repair ─────────────────────────────────────────────────────────────────

test "contract: repairNode on single-block node succeeds" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    try graph.repairNode(source);
    try graph.validate();
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "contract: repairBudgeted returns repaired count" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..64) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }
    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired <= 1);
    try graph.validate();
}

test "contract: repairBudgeted with max_nodes=0 returns 0" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(@as(usize, 0), try graph.repairBudgeted(0));
}

// ── Validation ─────────────────────────────────────────────────────────────

test "contract: validate passes on empty graph" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();
    try graph.validate();
}

test "contract: validate passes after addEdge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    try graph.validate();
}

test "contract: validate passes after removeEdge" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});
    _ = try graph.removeEdge(source, destination);
    try graph.validate();
}

test "contract: debugValidate on empty graph returns no violations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "contract: debugValidate on clean graph returns no violations" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    const violations = try graph.debugValidate(testing.allocator);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// ── Algorithms ─────────────────────────────────────────────────────────────

test "contract: bfs returns reachable nodes in BFS order" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    const middle = try graph.addNode();
    const leaf = try graph.addNode();
    try graph.addEdge(start, middle, 0, .{});
    try graph.addEdge(start, leaf, 0, .{});

    const order = try graph.bfs(start, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(start.index, order[0].index);
}

test "contract: dfs returns reachable nodes" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const start = try graph.addNode();
    const reachable = try graph.addNode();
    try graph.addEdge(start, reachable, 0, .{});

    const order = try graph.dfs(start, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expect(order.len >= 1);
    try testing.expectEqual(start.index, order[0].index);
}

test "contract: hasCycle on DAG returns false" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    try testing.expectEqual(false, try graph.hasCycle(testing.allocator));
}

test "contract: hasCycle on cycle returns true" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const first = try graph.addNode();
    const second = try graph.addNode();
    try graph.addEdge(first, second, 0, .{});
    try graph.addEdge(second, first, 0, .{});

    try testing.expectEqual(true, try graph.hasCycle(testing.allocator));
}

test "contract: hasCycle can return OutOfMemory" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var graph = try graphz.Graph.init(failing_allocator.allocator());
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, graph.hasCycle(failing_allocator.allocator()));
}

test "contract: outDegree and inDegree are consistent with neighbors materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, .{});

    const out_deg = try graph.outDegree(source);
    const in_deg = try graph.inDegree(source);
    try testing.expectEqual(@as(usize, 1), out_deg);
    try testing.expectEqual(@as(usize, 0), in_deg);

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const neighbors = try iter.materialize(testing.allocator);
    defer testing.allocator.free(neighbors);

    const expected_deg = try graph.outDegree(source);
    try testing.expectEqual(expected_deg, neighbors.len);
}

test "contract: neighborsMaterialized convenience matches neighbors + materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const first_dst = try graph.addNode();
    const second_dst = try graph.addNode();
    try graph.addEdge(source, first_dst, 0, .{});
    try graph.addEdge(source, second_dst, 0, .{});

    const direct = try graph.neighborsMaterialized(source, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    const via_iter = try iter.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
    for (direct, 0..) |neighbor, idx| {
        try testing.expectEqual(neighbor.index, via_iter[idx].index);
    }
}

test "contract: inNeighborsMaterialized convenience matches inNeighbors + materialize" {
    var graph = try graphz.Graph.init(testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode();
    const predecessor_one = try graph.addNode();
    const predecessor_two = try graph.addNode();
    try graph.addEdge(predecessor_one, target, 0, .{});
    try graph.addEdge(predecessor_two, target, 1, .{});

    const direct = try graph.inNeighborsMaterialized(target, testing.allocator);
    defer testing.allocator.free(direct);

    var iter = try graph.inNeighbors(target);
    defer iter.deinit();
    const via_iter = try iter.materialize(testing.allocator);
    defer testing.allocator.free(via_iter);

    try testing.expectEqual(direct.len, via_iter.len);
}

// ── GraphBuilder ───────────────────────────────────────────────────────────

test "contract: builder freeze returns valid mutable Graph handle" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    var iter = try graph.neighbors(source);
    defer iter.deinit();
    try testing.expectEqual(destination.index, iter.next().?.index);
}

test "contract: builder freeze on empty builder succeeds" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    try testing.expectEqual(@as(usize, 0), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "contract: builder freeze OutOfMemory leaves builder usable" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try graphz.GraphBuilder.init(failing_allocator.allocator());
    defer builder.deinit();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, builder.freeze());

    failing_allocator.fail_index = std.math.maxInt(usize);
    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
}

test "contract: builder freeze internal OutOfMemory leaves builder usable" {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try graphz.GraphBuilder.init(failing_allocator.allocator());
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    // Let the public graph handle allocation succeed, then fail on the first
    // allocation needed by the internal freeze preflight.
    failing_allocator.fail_index = failing_allocator.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, builder.freeze());

    failing_allocator.fail_index = std.math.maxInt(usize);
    var graph = try builder.freeze();
    defer graph.deinit();
    try graph.validate();
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}

test "contract: builder freeze with nodes but no edges succeeds" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    _ = try builder.addNode();
    _ = try builder.addNode();
    _ = try builder.addNode();

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    try testing.expectEqual(@as(usize, 3), graph.nodeCount());
    try testing.expectEqual(@as(u64, 0), graph.edgeCount());
    try graph.validate();
}

test "contract: builder become inert after freeze" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    _ = try builder.addNode();
    var graph = try builder.freeze();
    defer graph.deinit();
    defer builder.deinit();

    try testing.expectError(error.UnsupportedOperation, builder.addNode());
    try testing.expectError(error.UnsupportedOperation, builder.freeze());
}

test "contract: builder lifetime is independent of frozen graph" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const node = try builder.addNode();

    var graph = try builder.freeze();
    builder.deinit();

    try testing.expect(graph.hasNode(node));
    graph.deinit();
}

test "contract: frozen graph from builder supports mutations" {
    var builder = try graphz.GraphBuilder.init(testing.allocator);
    const source = try builder.addNode();
    const destination = try builder.addNode();
    try builder.addEdge(source, destination, 0, .{});

    var graph = try builder.freeze();
    defer graph.deinit();
    builder.deinit();

    const extra = try graph.addNode();
    try graph.addEdge(destination, extra, 1, .{});
    try graph.validate();
    try testing.expectEqual(@as(u64, 2), graph.edgeCount());

    var iter = try graph.neighbors(destination);
    defer iter.deinit();
    try testing.expectEqual(extra.index, iter.next().?.index);

    var reverse_iter = try graph.neighbors(source);
    defer reverse_iter.deinit();
    try testing.expectEqual(destination.index, reverse_iter.next().?.index);
}

// ── Concurrent mutation contract ──────────────────────────────────────────

test "contract: repairBudgeted returns ConcurrentMutation when another repairer is active" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    // Create repair debt: fill blocks, then drop occupancy below threshold.
    const source = try graph.addNode();
    var targets: [130]graphz.NodeId = undefined;
    for (0..130) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, .{});
    }
    // Remove edges to leave underfull blocks with real repair debt.
    var removed: usize = 0;
    for (targets[0..]) |t| {
        if (removed >= 90) break;
        if (graph.removeEdge(source, t)) |did_remove| {
            if (did_remove) removed += 1;
        } else |_| return;
    }

    var start_gate = std.atomic.Value(u32).init(2);
    var results = [_]?graphz.GraphError!usize{ null, null };

    const Ctx = struct {
        graph: *graphz.Graph,
        start_gate: *std.atomic.Value(u32),
        result: *?graphz.GraphError!usize,
        fn run(ctx: @This()) void {
            _ = ctx.start_gate.fetchSub(1, .acq_rel);
            while (ctx.start_gate.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }
            // Loop until we get either success or ConcurrentMutation,
            // avoiding both threads exiting before contention occurs.
            var attempts: usize = 0;
            while (attempts < 200) : (attempts += 1) {
                const outcome = ctx.graph.repairBudgeted(10);
                ctx.result.* = outcome;
                if (outcome) |_| return else |err| {
                    if (err == error.ConcurrentMutation) return;
                }
                std.atomic.spinLoopHint();
            }
            ctx.result.* = null;
        }
    };

    const ctx_one = Ctx{ .graph = graph, .start_gate = &start_gate, .result = &results[0] };
    const ctx_two = Ctx{ .graph = graph, .start_gate = &start_gate, .result = &results[1] };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{ctx_one});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{ctx_two});
    t1.join();
    t2.join();

    const inner_one = results[0] orelse return error.TestExpectedEqual;
    const inner_two = results[1] orelse return error.TestExpectedEqual;

    const one_ok = if (inner_one) |_| true else |_| false;
    const two_ok = if (inner_two) |_| true else |_| false;
    try testing.expect(one_ok != two_ok);
    if (!one_ok) _ = inner_one catch |err| try testing.expectEqual(error.ConcurrentMutation, err);
    if (!two_ok) _ = inner_two catch |err| try testing.expectEqual(error.ConcurrentMutation, err);

    try graph.validate();
}

test "contract: repairBudgeted retry after ConcurrentMutation succeeds" {
    const allocator = std.heap.page_allocator;
    var graph = try graphz.Graph.init(allocator);
    defer graph.deinit();

    // Create repair debt.
    const source = try graph.addNode();
    var targets: [130]graphz.NodeId = undefined;
    for (0..130) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, .{});
    }
    var removed: usize = 0;
    for (targets[0..]) |t| {
        if (removed >= 90) break;
        if (graph.removeEdge(source, t)) |did_remove| {
            if (did_remove) removed += 1;
        } else |_| return;
    }

    var stop = std.atomic.Value(bool).init(false);
    var success_count = std.atomic.Value(u32).init(0);

    const Worker = struct {
        graph: *graphz.Graph,
        stop: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),
        fn run(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                const outcome = ctx.graph.repairBudgeted(10);
                if (outcome) |count| {
                    if (count > 0) _ = ctx.successes.fetchAdd(1, .monotonic);
                } else |err| {
                    if (err != error.ConcurrentMutation) return;
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    const worker = Worker{ .graph = graph, .stop = &stop, .successes = &success_count };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{worker});

    // Retry until we observe at least one success.
    var attempt: usize = 0;
    while (attempt < 5000) : (attempt += 1) {
        if (graph.repairBudgeted(10)) |_| {
            break;
        } else |err| {
            if (err != error.ConcurrentMutation) return err;
        }
        std.atomic.spinLoopHint();
    }
    try testing.expect(attempt < 5000);

    stop.store(true, .release);
    worker_thread.join();

    try testing.expect(success_count.load(.acquire) > 0);

    try graph.validate();
}
