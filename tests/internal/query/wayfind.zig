//! Acceptance tests for Wayfind: builder → IR, IR validation (including
//! hostile bytes), and plan execution over captured snapshot views.

const std = @import("std");
const testing = std.testing;
const graph_mod = @import("graph_mod");

const wayfind = graph_mod.wayfind_mod;
const ir = graph_mod.wayfind_ir_mod;
const exec = graph_mod.wayfind_exec_mod;
const Query = wayfind.Query;
const Context = graph_mod.algorithms_context_mod.Context;

const ctx: Context = .{ .allocator = testing.allocator };

// Force full semantic analysis of the stack even while nothing calls it.
test "wayfind: modules compile" {
    testing.refAllDecls(wayfind);
    testing.refAllDecls(ir);
    testing.refAllDecls(graph_mod.wayfind_builder_mod);
    testing.refAllDecls(exec);
    testing.refAllDecls(graph_mod.wayfind_parser_mod);
}

// ── builder → IR ─────────────────────────────────────────────────────────

test "builder: pipeline compiles to the expected step sequence" {
    const plan = comptime Query.fromParam(0)
        .out(7, .{ .min = 1, .max = 3 })
        .intersectParam(1)
        .minusParam(2)
        .ids();

    const expected = [_]ir.Step{
        .{ .op = .seed_param, .param = 0 },
        .{ .op = .expand, .dir = .out, .rel = 7, .hops = .{ .min = 1, .max = 3 } },
        .{ .op = .seed_param, .param = 1 },
        .{ .op = .set_intersect },
        .{ .op = .seed_param, .param = 2 },
        .{ .op = .set_minus },
        .{ .op = .emit_ids },
    };
    try testing.expectEqualSlices(ir.Step, &expected, plan.steps);
    try testing.expectEqual(@as(u16, 3), plan.param_count);
}

test "builder: closure and degree filter encode their sentinels" {
    const plan = comptime Query.fromNode(17)
        .outClosure(ir.ANY_RELATION)
        .filterDegree(.in, .ge, 2)
        .count();

    try testing.expectEqual(@as(usize, 4), plan.steps.len);
    try testing.expectEqual(ir.Op.seed_node, plan.steps[0].op);
    try testing.expectEqual(@as(u32, 17), plan.steps[0].arg);
    try testing.expectEqual(ir.UNBOUNDED, plan.steps[1].hops.max);
    try testing.expectEqual(ir.ANY_RELATION, plan.steps[1].rel);
    try testing.expectEqual(ir.Cmp.ge, plan.steps[2].cmp);
    try testing.expectEqual(@as(u16, 0), plan.param_count);
}

// ── ir.validate ──────────────────────────────────────────────────────────

test "validate: accepts every builder-produced plan" {
    const plans = comptime [_]ir.Plan{
        Query.fromParam(0).out(7, .{ .min = 1, .max = 3 }).intersectParam(1).minusParam(2).ids(),
        Query.fromNode(17).outClosure(ir.ANY_RELATION).filterDegree(.in, .ge, 2).count(),
        Query.allNodes().exists(),
        Query.fromParam(0).both(ir.ANY_RELATION, .{ .min = 0, .max = 2 }).unionParam(1).edges(),
        Query.fromNode(0).in(5, .{ .min = 1, .max = 1 }).csr(),
    };
    inline for (plans) |plan| try ir.validate(plan);
}

test "validate: rejects stack underflow, early and missing terminal" {
    // Set op with a single operand.
    try testing.expectError(error.StackUnderflow, ir.validate(.{
        .steps = &.{ .{ .op = .seed_node, .arg = 1 }, .{ .op = .set_union }, .{ .op = .emit_ids } },
        .param_count = 0,
    }));
    // Transform with no source.
    try testing.expectError(error.StackUnderflow, ir.validate(.{
        .steps = &.{ .{ .op = .expand }, .{ .op = .emit_ids } },
        .param_count = 0,
    }));
    // No terminal.
    try testing.expectError(error.MissingTerminal, ir.validate(.{
        .steps = &.{.{ .op = .seed_node, .arg = 1 }},
        .param_count = 0,
    }));
    try testing.expectError(error.MissingTerminal, ir.validate(.{ .steps = &.{}, .param_count = 0 }));
    // Terminal mid-plan.
    try testing.expectError(error.EarlyTerminal, ir.validate(.{
        .steps = &.{ .{ .op = .seed_node, .arg = 1 }, .{ .op = .emit_ids }, .{ .op = .emit_ids } },
        .param_count = 0,
    }));
    // Terminal leaving a second set on the stack.
    try testing.expectError(error.MissingTerminal, ir.validate(.{
        .steps = &.{ .{ .op = .seed_node, .arg = 1 }, .{ .op = .seed_node, .arg = 2 }, .{ .op = .emit_ids } },
        .param_count = 0,
    }));
}

test "validate: rejects hostile bytes and dirty operands" {
    // Out-of-range op decoded from raw bytes (never via @enumFromInt).
    var hostile_bytes = [_]u8{0} ** 16;
    std.mem.writeInt(u16, hostile_bytes[0..2], 999, .little);
    const hostile_step: ir.Step = @bitCast(hostile_bytes);
    try testing.expectError(error.InvalidEnum, ir.validate(.{
        .steps = &.{hostile_step},
        .param_count = 0,
    }));

    // Out-of-range dir byte on a valid op.
    var bad_dir = [_]u8{0} ** 16;
    std.mem.writeInt(u16, bad_dir[0..2], @intFromEnum(ir.Op.expand), .little);
    bad_dir[2] = 7;
    std.mem.writeInt(u16, bad_dir[4..6], ir.ANY_RELATION, .little);
    std.mem.writeInt(u16, bad_dir[8..10], 1, .little); // hops.min
    std.mem.writeInt(u16, bad_dir[10..12], 1, .little); // hops.max
    bad_dir[3] = @intFromEnum(ir.Cmp.ge);
    const bad_dir_step: ir.Step = @bitCast(bad_dir);
    try testing.expectError(error.InvalidEnum, ir.validate(.{
        .steps = &.{ .{ .op = .seed_node, .arg = 0 }, bad_dir_step, .{ .op = .emit_ids } },
        .param_count = 0,
    }));

    // Param slot out of range.
    try testing.expectError(error.UnknownParam, ir.validate(.{
        .steps = &.{ .{ .op = .seed_param, .param = 2 }, .{ .op = .emit_ids } },
        .param_count = 2,
    }));

    // hops.min > hops.max.
    try testing.expectError(error.InvalidHops, ir.validate(.{
        .steps = &.{
            .{ .op = .seed_node, .arg = 0 },
            .{ .op = .expand, .hops = .{ .min = 3, .max = 1 } },
            .{ .op = .emit_ids },
        },
        .param_count = 0,
    }));

    // Operand set for an op that does not use it (arg on emit).
    try testing.expectError(error.DirtyOperand, ir.validate(.{
        .steps = &.{ .{ .op = .seed_node, .arg = 0 }, .{ .op = .emit_ids, .arg = 5 } },
        .param_count = 0,
    }));
}

// ── parser ───────────────────────────────────────────────────────────────

test "parser: textual pipeline produces the same plan as the builder" {
    var parsed = try wayfind.parse(testing.allocator,
        \\# friends-of-friends, filtered by an injected set
        \\from $seeds
        \\| out(follows){1..3}
        \\| & $active
        \\| - $blocked
        \\| ids
    , &.{.{ .name = "follows", .value = 7 }});
    defer parsed.deinit(testing.allocator);

    const built = comptime Query.fromParam(0)
        .out(7, .{ .min = 1, .max = 3 })
        .intersectParam(1)
        .minusParam(2)
        .ids();
    try testing.expectEqualSlices(ir.Step, built.steps, parsed.steps);
    try testing.expectEqual(built.param_count, parsed.plan().param_count);
}

test "parser: parameter slots are dense, by first appearance, reused by name" {
    var parsed = try wayfind.parse(testing.allocator, "from $a | & $b | + $a | ids", &.{});
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), parsed.plan().param_count);
    try testing.expectEqual(@as(u16, 0), parsed.paramSlot("a").?);
    try testing.expectEqual(@as(u16, 1), parsed.paramSlot("b").?);
    try testing.expectEqual(@as(?u16, null), parsed.paramSlot("missing"));
    // The repeated $a re-seeds slot 0.
    try testing.expectEqual(@as(u16, 0), parsed.steps[3].param);
}

test "parser: sources, ranges, closure, degree and numeric relations" {
    var parsed = try wayfind.parse(testing.allocator, "from node:17 | out(9)* | in{0..2} | both(5){2..*} | degree(in) >= 2 | count", &.{});
    defer parsed.deinit(testing.allocator);

    const expected = [_]ir.Step{
        .{ .op = .seed_node, .arg = 17 },
        .{ .op = .expand, .dir = .out, .rel = 9, .hops = .{ .min = 1, .max = ir.UNBOUNDED } },
        .{ .op = .expand, .dir = .in, .hops = .{ .min = 0, .max = 2 } },
        .{ .op = .expand, .dir = .both, .rel = 5, .hops = .{ .min = 2, .max = ir.UNBOUNDED } },
        .{ .op = .filter_degree, .dir = .in, .cmp = .ge, .arg = 2 },
        .{ .op = .emit_count },
    };
    try testing.expectEqualSlices(ir.Step, &expected, parsed.steps);

    var all = try wayfind.parse(testing.allocator, "from * | exists", &.{});
    defer all.deinit(testing.allocator);
    try testing.expectEqual(ir.Op.all_nodes, all.steps[0].op);
    try testing.expectEqual(ir.Op.emit_exists, all.steps[1].op);
}

test "parser: rejects malformed queries and unknown relations" {
    const cases = [_]struct { source: []const u8, expected: anyerror }{
        .{ .source = "from $a", .expected = error.MissingTerminal },
        .{ .source = "from $a | ids | ids", .expected = error.UnexpectedToken },
        .{ .source = "from $a | out(nope) | ids", .expected = error.UnknownRelation },
        .{ .source = "from $a | out(65535) | ids", .expected = error.ReservedRelation },
        .{ .source = "from $a | out{3..1} | ids", .expected = error.InvalidHops },
        .{ .source = "match (a)-->(b)", .expected = error.UnexpectedToken },
        .{ .source = "from node:99999999999 | ids", .expected = error.NumberOverflow },
        .{ .source = "", .expected = error.UnexpectedEnd },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, wayfind.parse(testing.allocator, case.source, &.{}));
    }
}

// ── exec fixtures ────────────────────────────────────────────────────────

const Fixture = struct {
    graph: graph_mod.Graph,
    nodes: [8]graph_mod.NodeId,

    /// Layout (relation 1 unless noted):
    ///   chain 0→1→2→3, branch 0→4, cross 4→2 (relation 2),
    ///   back-edge 3→0 (relation 2), hub 5 → {0,1,2,3,4,6},
    ///   6 reached from 5 only, 7 fully isolated.
    fn init() !Fixture {
        var graph = try graph_mod.Graph.init(testing.allocator);
        errdefer graph.deinit();
        var nodes: [8]graph_mod.NodeId = undefined;
        for (0..nodes.len) |i| nodes[i] = try graph.addNode();

        try graph.addEdge(nodes[0], nodes[1], 1, 0);
        try graph.addEdge(nodes[1], nodes[2], 1, 0);
        try graph.addEdge(nodes[2], nodes[3], 1, 0);
        try graph.addEdge(nodes[0], nodes[4], 1, 0);
        try graph.addEdge(nodes[4], nodes[2], 2, 0);
        try graph.addEdge(nodes[3], nodes[0], 2, 0);
        for ([_]usize{ 0, 1, 2, 3, 4, 6 }) |destination| {
            try graph.addEdge(nodes[5], nodes[destination], 1, 0);
        }
        return .{ .graph = graph, .nodes = nodes };
    }

    fn deinit(self: *Fixture) void {
        self.graph.deinit();
    }
};

fn expectIds(result: *exec.Result, expected: []const u32) !void {
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, expected, result.ids);
}

// ── exec ─────────────────────────────────────────────────────────────────

test "exec: expand one hop equals the snapshot's neighbor sets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    for (fixture.nodes) |node| {
        const plan = comptime Query.fromParam(0).out(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).ids();
        var result = try exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{&.{node.index}} });
        defer result.deinit(testing.allocator);

        const neighbors = try snapshot.neighborsMaterialized(node, ctx);
        defer testing.allocator.free(neighbors);
        var expected: std.ArrayList(u32) = .empty;
        defer expected.deinit(testing.allocator);
        for (neighbors) |neighbor| try expected.append(testing.allocator, neighbor.index);
        std.mem.sort(u32, expected.items, {}, std.sort.asc(u32));

        try testing.expectEqualSlices(u32, expected.items, result.ids);
    }

    // Same parity for the reverse direction.
    for (fixture.nodes) |node| {
        const plan = comptime Query.fromParam(0).in(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).ids();
        var result = try exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{&.{node.index}} });
        defer result.deinit(testing.allocator);

        const neighbors = try snapshot.inNeighborsMaterialized(node, ctx);
        defer testing.allocator.free(neighbors);
        var expected: std.ArrayList(u32) = .empty;
        defer expected.deinit(testing.allocator);
        for (neighbors) |neighbor| try expected.append(testing.allocator, neighbor.index);
        std.mem.sort(u32, expected.items, {}, std.sort.asc(u32));

        try testing.expectEqualSlices(u32, expected.items, result.ids);
    }
}

test "exec: expand closure equals bfs reachability" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    const bfs_order = try graph_mod.bfs_mod.bfsCaptured(&snapshot.view, fixture.nodes[0], ctx);
    defer testing.allocator.free(bfs_order);
    var bfs_set: std.ArrayList(u32) = .empty;
    defer bfs_set.deinit(testing.allocator);
    for (bfs_order) |node| try bfs_set.append(testing.allocator, node.index);
    std.mem.sort(u32, bfs_set.items, {}, std.sort.asc(u32));

    // {0..*} includes hop 0 — exactly the BFS visit set.
    const with_start = comptime Query.fromNode(0).expand(.out, ir.ANY_RELATION, .{ .min = 0, .max = ir.UNBOUNDED }).ids();
    var closed = try exec.run(with_start, &snapshot.view, ctx, .{});
    try expectIds(&closed, bfs_set.items);

    // {1..*} excludes level-0 nodes even though 0 sits on a cycle (3→0):
    // an input node re-reached in k>0 hops keeps level 0.
    const without_start = comptime Query.fromNode(0).outClosure(ir.ANY_RELATION).ids();
    var reachable = try exec.run(without_start, &snapshot.view, ctx, .{});
    defer reachable.deinit(testing.allocator);
    for (reachable.ids) |id| try testing.expect(id != fixture.nodes[0].index);
    try testing.expectEqual(bfs_set.items.len - 1, reachable.ids.len);
}

test "exec: hop ranges respect min and max levels" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();
    const n = fixture.nodes;

    // From 0: level 1 = {1,4}, level 2 = {2}, level 3 = {3}.
    const two_three = comptime Query.fromNode(0).out(ir.ANY_RELATION, .{ .min = 2, .max = 3 }).ids();
    var mid = try exec.run(two_three, &snapshot.view, ctx, .{});
    try expectIds(&mid, &.{ n[2].index, n[3].index });

    const zero_one = comptime Query.fromNode(0).out(ir.ANY_RELATION, .{ .min = 0, .max = 1 }).ids();
    var near = try exec.run(zero_one, &snapshot.view, ctx, .{});
    try expectIds(&near, &.{ n[0].index, n[1].index, n[4].index });

    // {0..0} is the identity.
    const identity = comptime Query.fromNode(2).out(ir.ANY_RELATION, .{ .min = 0, .max = 0 }).ids();
    var same = try exec.run(identity, &snapshot.view, ctx, .{});
    try expectIds(&same, &.{n[2].index});
}

test "exec: relation filter expands only matching edges" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();
    const n = fixture.nodes;

    // Node 4 has a single out-edge, 4→2, with relation 2.
    const rel1 = comptime Query.fromNode(4).out(1, .{ .min = 1, .max = 1 }).ids();
    var none = try exec.run(rel1, &snapshot.view, ctx, .{});
    try expectIds(&none, &.{});

    const rel2 = comptime Query.fromNode(4).out(2, .{ .min = 1, .max = 1 }).ids();
    var crossed = try exec.run(rel2, &snapshot.view, ctx, .{});
    try expectIds(&crossed, &.{n[2].index});

    // Reverse with relation: in-neighbors of 2 are 1 (rel 1), 4 (rel 2), 5 (rel 1).
    const in_rel2 = comptime Query.fromNode(2).in(2, .{ .min = 1, .max = 1 }).ids();
    var via_rel2 = try exec.run(in_rel2, &snapshot.view, ctx, .{});
    try expectIds(&via_rel2, &.{n[4].index});

    const in_rel1 = comptime Query.fromNode(2).in(1, .{ .min = 1, .max = 1 }).ids();
    var via_rel1 = try exec.run(in_rel1, &snapshot.view, ctx, .{});
    try expectIds(&via_rel1, &.{ n[1].index, n[5].index });

    // `both` unions the two directions around 0: out {1,4}, in {3,5}.
    const both_any = comptime Query.fromNode(0).both(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).ids();
    var around = try exec.run(both_any, &snapshot.view, ctx, .{});
    try expectIds(&around, &.{ n[1].index, n[3].index, n[4].index, n[5].index });
}

test "exec: set ops against params honor pipeline order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();
    const n = fixture.nodes;

    // ({0,1} ∖ {1,2}) = {0} — minus is accumulated ∖ param, never reversed.
    const minus = comptime Query.fromParam(0).minusParam(1).ids();
    var difference = try exec.run(minus, &snapshot.view, ctx, .{ .sets = &.{
        &.{ n[0].index, n[1].index },
        &.{ n[1].index, n[2].index },
    } });
    try expectIds(&difference, &.{n[0].index});

    const intersect = comptime Query.fromParam(0).intersectParam(1).ids();
    var common = try exec.run(intersect, &snapshot.view, ctx, .{ .sets = &.{
        &.{ n[0].index, n[1].index, n[2].index },
        &.{ n[1].index, n[2].index, n[3].index },
    } });
    try expectIds(&common, &.{ n[1].index, n[2].index });

    const join = comptime Query.fromParam(0).unionParam(1).ids();
    var merged = try exec.run(join, &snapshot.view, ctx, .{ .sets = &.{
        &.{n[0].index},
        &.{n[7].index},
    } });
    try expectIds(&merged, &.{ n[0].index, n[7].index });
}

test "exec: terminals — ids sorted, count, exists, degree filter" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();
    const n = fixture.nodes;

    // ids: injected unsorted with duplicates, emitted sorted unique.
    const ids_plan = comptime Query.fromParam(0).ids();
    var sorted = try exec.run(ids_plan, &snapshot.view, ctx, .{ .sets = &.{
        &.{ n[3].index, n[0].index, n[3].index, n[1].index },
    } });
    try expectIds(&sorted, &.{ n[0].index, n[1].index, n[3].index });

    const count_plan = comptime Query.allNodes().count();
    var total = try exec.run(count_plan, &snapshot.view, ctx, .{});
    defer total.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 8), total.count);

    const exists_plan = comptime Query.fromNode(7).out(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).exists();
    var empty = try exec.run(exists_plan, &snapshot.view, ctx, .{});
    defer empty.deinit(testing.allocator);
    try testing.expect(!empty.exists);

    // degree(out) >= 4 keeps only the hub (out-degree 6).
    const hubs_plan = comptime Query.allNodes().filterDegree(.out, .ge, 4).ids();
    var hubs = try exec.run(hubs_plan, &snapshot.view, ctx, .{});
    try expectIds(&hubs, &.{n[5].index});
}

test "exec: emit_edges returns in-set edges with prop rows" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .edge_properties = true });
    defer graph.deinit();
    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();

    const row_01 = try graph.addEdgeWithProperties(nodes[0], nodes[1], 1, 0);
    const row_12 = try graph.addEdgeWithProperties(nodes[1], nodes[2], 1, 0);
    _ = try graph.addEdgeWithProperties(nodes[2], nodes[3], 1, 0); // 3 is outside the set

    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    const plan = comptime Query.fromParam(0).edges();
    var result = try exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{
        &.{ nodes[0].index, nodes[1].index, nodes[2].index },
    } });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.edges.len);
    try testing.expectEqual(ir.EdgeRow{ .source = nodes[0].index, .destination = nodes[1].index, .prop_row = row_01 }, result.edges[0]);
    try testing.expectEqual(ir.EdgeRow{ .source = nodes[1].index, .destination = nodes[2].index, .prop_row = row_12 }, result.edges[1]);

    // Cross-check against the engine's own row lookup.
    for (result.edges) |edge| {
        const row = try graph.edgePropertyRow(.{ .index = edge.source }, .{ .index = edge.destination });
        try testing.expectEqual(edge.prop_row, row.?);
    }
}

test "exec: emit_csr builds the induced subgraph" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();
    const n = fixture.nodes;

    // Members {0,1,2}: induced edges 0→1 and 1→2 (0→4 and 2→3 leave the set).
    const plan = comptime Query.fromParam(0).csr();
    var result = try exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{
        &.{ n[0].index, n[1].index, n[2].index },
    } });
    defer result.deinit(testing.allocator);

    const csr = result.csr;
    try testing.expectEqual(@as(usize, 8), csr.nodeCount());
    try testing.expectEqual(@as(u64, 2), csr.edgeCount());
    try testing.expectEqualSlices(u32, &.{n[1].index}, try csr.outNeighbors(n[0]));
    try testing.expectEqualSlices(u32, &.{n[2].index}, try csr.outNeighbors(n[1]));
    try testing.expectEqual(@as(usize, 0), (try csr.outNeighbors(n[2])).len);
    // Non-members read as not live (empty offsets, membership bitmap).
    try testing.expect(!csr.isLive(n[5]));
    try testing.expectError(error.InvalidNode, csr.outNeighbors(n[5]));
}

test "exec: param binding rejects mismatched count and invalid ids" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    const plan = comptime Query.fromParam(0).intersectParam(1).ids();
    try testing.expectError(error.ParamCountMismatch, exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{
        &.{fixture.nodes[0].index},
    } }));

    const single = comptime Query.fromParam(0).ids();
    try testing.expectError(error.InvalidNode, exec.run(single, &snapshot.view, ctx, .{ .sets = &.{
        &.{ fixture.nodes[0].index, 999 },
    } }));
}

test "exec: removed param ids drop silently; removed seeds error" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();
    var nodes: [3]graph_mod.NodeId = undefined;
    for (0..nodes.len) |i| nodes[i] = try graph.addNode();
    try graph.addEdge(nodes[0], nodes[1], 1, 0);
    _ = try graph.removeNode(nodes[2]);

    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    // Stale set containing the removed node: dropped, not an error.
    const plan = comptime Query.fromParam(0).ids();
    var live_only = try exec.run(plan, &snapshot.view, ctx, .{ .sets = &.{
        &.{ nodes[0].index, nodes[2].index },
    } });
    try expectIds(&live_only, &.{nodes[0].index});

    // A removed explicit seed is a bug in the query, not staleness.
    const seed_removed = comptime Query.fromNode(2).ids();
    try testing.expectError(error.InvalidNode, exec.run(seed_removed, &snapshot.view, ctx, .{}));
}

test "exec: a running query is isolated from later mutations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    // Mutate AFTER capturing: new edge 7→0 and a brand-new node.
    try fixture.graph.addEdge(fixture.nodes[7], fixture.nodes[0], 1, 0);
    _ = try fixture.graph.addNode();

    // The snapshot still sees 7 as isolated and 8 nodes total.
    const out_of_7 = comptime Query.fromNode(7).out(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).ids();
    var still_isolated = try exec.run(out_of_7, &snapshot.view, ctx, .{});
    try expectIds(&still_isolated, &.{});

    const in_of_0 = comptime Query.fromNode(0).in(ir.ANY_RELATION, .{ .min = 1, .max = 1 }).ids();
    var unchanged = try exec.run(in_of_0, &snapshot.view, ctx, .{});
    try expectIds(&unchanged, &.{ fixture.nodes[3].index, fixture.nodes[5].index });

    const count_plan = comptime Query.allNodes().count();
    var total = try exec.run(count_plan, &snapshot.view, ctx, .{});
    defer total.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 8), total.count);
}

test "parser: a parsed query executes identically to its builder twin" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    var parsed = try wayfind.parse(testing.allocator, "from $seeds | out(rel1){1..2} | - $blocked | ids", &.{.{ .name = "rel1", .value = 1 }});
    defer parsed.deinit(testing.allocator);

    const seeds = [_]u32{fixture.nodes[0].index};
    const blocked = [_]u32{fixture.nodes[2].index};

    // Bind by name, not by position — the table is the contract.
    var sets: [2][]const u32 = undefined;
    sets[parsed.paramSlot("seeds").?] = &seeds;
    sets[parsed.paramSlot("blocked").?] = &blocked;

    var from_text = try exec.run(parsed.plan(), &snapshot.view, ctx, .{ .sets = &sets });
    defer from_text.deinit(testing.allocator);

    const twin = comptime Query.fromParam(0).out(1, .{ .min = 1, .max = 2 }).minusParam(1).ids();
    var from_builder = try exec.run(twin, &snapshot.view, ctx, .{ .sets = &.{ &seeds, &blocked } });
    defer from_builder.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, from_builder.ids, from_text.ids);
}
