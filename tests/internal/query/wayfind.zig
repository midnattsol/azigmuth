//! Acceptance tests for Wayfind. The builder
//! tests run today (the builder is pure comptime data); validate/exec tests
//! start skipped — flip each `return error.SkipZigTest;` into a real body
//! as its piece lands.

const std = @import("std");
const testing = std.testing;
const graph_mod = @import("graph_mod");

const wayfind = graph_mod.wayfind_mod;
const ir = wayfind.ir;
const Query = wayfind.Query;

// Force full semantic analysis of the stack even while nothing calls it.
test "wayfind: modules compile" {
    testing.refAllDecls(wayfind);
    testing.refAllDecls(ir);
    testing.refAllDecls(wayfind.builder);
    testing.refAllDecls(wayfind.exec);
}

// ── builder → IR (runnable today) ────────────────────────────────────────

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
    // TODO: a handful of representative builder pipelines must pass
    // ir.validate — the two surfaces must agree on what well-formed means.
    return error.SkipZigTest;
}

test "validate: rejects stack underflow, early/missing terminal" {
    // TODO: hand-built step arrays — set op with one operand
    // (StackUnderflow), no terminal (MissingTerminal), terminal mid-plan
    // (EarlyTerminal).
    return error.SkipZigTest;
}

test "validate: rejects hostile bytes and dirty operands" {
    // TODO: out-of-range op/dir/cmp via @bitCast'd bytes (InvalidEnum,
    // never @enumFromInt UB), param >= param_count (UnknownParam),
    // hops.min > hops.max (InvalidHops), nonzero unused operand fields
    // (DirtyOperand).
    return error.SkipZigTest;
}

// ── exec ─────────────────────────────────────────────────────────────────
// Build one shared fixture graph: a few nodes with block adjacency, one
// tiny node, two relation kinds, then snapshot it (the captured view is
// what exec runs against).

test "exec: expand one hop equals the snapshot's neighbor sets" {
    // TODO: from each node, out(any){1..1} | ids == sorted neighbors()
    // of the snapshot; same for `in`.
    return error.SkipZigTest;
}

test "exec: expand closure equals bfs reachability" {
    // TODO: fromNode(n).outClosure(any).ids() == set of bfsCaptured(n)
    // (order-insensitive), including hop-0 exclusion semantics.
    return error.SkipZigTest;
}

test "exec: hop ranges respect min and max levels" {
    // TODO: on a known chain a→b→c→d: {2..3} from a yields {c,d};
    // {0..1} yields {a,b}.
    return error.SkipZigTest;
}

test "exec: relation filter expands only matching edges" {
    return error.SkipZigTest;
}

test "exec: set ops against params honor pipeline order" {
    // TODO: & and - and + against injected sets; minus must be
    // (accumulated ∖ param), not the reverse.
    return error.SkipZigTest;
}

test "exec: terminals — ids sorted, count, exists short-circuit" {
    return error.SkipZigTest;
}

test "exec: emit_edges returns in-set edges with prop rows" {
    // TODO: edge_properties graph; every returned prop_row matches
    // edgePropertyRow of its (source,destination).
    return error.SkipZigTest;
}

test "exec: emit_csr builds the induced subgraph" {
    return error.SkipZigTest;
}

test "exec: param binding rejects mismatched count and invalid ids" {
    // TODO: ParamCountMismatch and InvalidNode; duplicates in a param set
    // are deduplicated, not an error.
    return error.SkipZigTest;
}

test "exec: a running query is isolated from later mutations" {
    // TODO: capture snapshot → mutate the live graph → run the plan →
    // results reflect the snapshot only (RCU anchoring).
    return error.SkipZigTest;
}
