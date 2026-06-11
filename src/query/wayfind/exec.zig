//! Wayfind plan executor (SKELETON: every body is a TODO).
//!
//! Runs a validated plan against one `CapturedGraphView` — a stack machine
//! over NodeSets. The recommended NodeSet representation is a paged bitmap
//! (`core/node_bitmap.zig`: set/test/testAndSet over node-indexed pages)
//! plus a live count; sorted `[]u32` is the output form.
//!
//! Reference material in-tree:
//!  - frontier loop shape + Context arenas: `algorithms/bfs.zig`
//!    (`bfsCaptured`),
//!  - per-node neighbor walk over a view: `query/snapshot/iterators.zig`
//!    (`forEachNeighborInView`, `neighborsCursor`),
//!  - CSR construction: `query/snapshot/csr.zig` (`materializeForwardCsr` —
//!    `emit_csr` is its induced-subgraph variant).
//!
//! Cost model contract: every step is one pass over its operand sets;
//! `expand{m..n}` is at most n frontier sweeps. Nothing here may introduce
//! hidden quadratic work — predictable cost is the language's reason to
//! exist.

const std = @import("std");
const ir = @import("ir.zig");
const types = @import("../../core/types.zig");
const node_bitmap = @import("../../core/node_bitmap.zig");
const snapshot_view = @import("../snapshot/view.zig");
const snapshot_iterators = @import("../snapshot/iterators.zig");
const snapshot_csr = @import("../snapshot/csr.zig");
const context_mod = @import("../../algorithms/context.zig");

/// Caller-provided parameter sets, indexed by plan slot. Bind semantics,
/// normative: duplicates are deduplicated; ids of
/// REMOVED nodes are silently dropped (stale sets from older snapshots
/// stay usable); out-of-range ids (>= nodeCount) are an `InvalidNode`
/// error — they were never valid, so they signal a bug, not staleness.
pub const Params = struct {
    sets: []const []const u32 = &.{},
};

pub const Result = union(enum) {
    /// Sorted ascending, no duplicates (normative).
    ids: []u32,
    count: u64,
    exists: bool,
    edges: []ir.EdgeRow,
    csr: snapshot_csr.CsrView,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ids => |payload| allocator.free(payload),
            .edges => |payload| allocator.free(payload),
            .csr => |*view| view.deinit(allocator),
            .count, .exists => {},
        }
        self.* = undefined;
    }
};

pub const ExecError = ir.PlanError || types.GraphError || error{
    /// params.sets.len != plan.param_count.
    ParamCountMismatch,
    /// A parameter set contains a node id >= view.nodeCount().
    InvalidNode,
};

/// Executes `plan` against `view`. Plans from the comptime builder are
/// structurally sound by construction; every other plan MUST have passed
/// `ir.validate` (run it here defensively — it is cheap relative to any
/// traversal).
pub fn run(
    plan: ir.Plan,
    view: *const snapshot_view.CapturedGraphView,
    ctx: context_mod.Context,
    params: Params,
) ExecError!Result {
    _ = plan;
    _ = view;
    _ = ctx;
    _ = params;
    // TODO orchestration:
    //   1. ir.validate(plan) (skip only if a comptime-builder marker says so;
    //      simplest v1: always validate).
    //   2. bind params: length check, materialize each slice as a NodeSet
    //      bitmap (dedup free), bounds-check ids against view.nodeCount().
    //   3. walk steps with a small fixed-depth NodeSet stack (validate
    //      bounded the depth): dispatch per op to the helpers below.
    //   4. the final terminal consumes the last set and builds Result.
    @panic("TODO: exec.run");
}

// ── Per-op helpers (the implementation work, one contract each) ──────────

/// Level-synchronous expand: from `input`, sweep frontiers following
/// `step.dir`/`step.rel`, accumulating every node first reached at hop
/// m..n into the result (hop 0 = the input itself when step.hops.min == 0).
/// Visited bitmap guarantees each node is expanded at most once — that is
/// both the termination proof for UNBOUNDED and the cost bound.
fn execExpand(
    view: *const snapshot_view.CapturedGraphView,
    ctx: context_mod.Context,
    input: NodeSet,
    step: ir.Step,
) ExecError!NodeSet {
    _ = view;
    _ = ctx;
    _ = input;
    _ = step;
    @panic("TODO: exec.execExpand");
}

/// Word-wise union/intersect/minus over the bitmap pages of two sets.
/// `set_minus` is (lower ∖ top) — see the Op doc.
fn execSetOp(op: ir.Op, lower: NodeSet, top: NodeSet) ExecError!NodeSet {
    _ = op;
    _ = lower;
    _ = top;
    @panic("TODO: exec.execSetOp");
}

/// Keep nodes whose `step.dir` degree satisfies `step.cmp step.arg`,
/// reading degrees from the view's adjacency snapshot.
fn execFilterDegree(
    view: *const snapshot_view.CapturedGraphView,
    input: NodeSet,
    step: ir.Step,
) ExecError!NodeSet {
    _ = view;
    _ = input;
    _ = step;
    @panic("TODO: exec.execFilterDegree");
}

/// Edges with BOTH endpoints in `set`, as (source, destination, prop_row):
/// walk the forward side of each member, keep targets that test the set
/// bitmap. prop_row = 0 when the graph has no edge properties. Output
/// sorted by (source, destination, prop_row) — normative determinism;
/// multigraph parallel edges appear once each.
fn emitEdges(
    view: *const snapshot_view.CapturedGraphView,
    ctx: context_mod.Context,
    set: NodeSet,
) ExecError![]ir.EdgeRow {
    _ = view;
    _ = ctx;
    _ = set;
    @panic("TODO: exec.emitEdges");
}

/// CSR of the induced subgraph (same shape as `materializeForwardCsr`,
/// restricted to members; targets keep their original node ids).
fn emitCsr(
    view: *const snapshot_view.CapturedGraphView,
    ctx: context_mod.Context,
    set: NodeSet,
) ExecError!snapshot_csr.CsrView {
    _ = view;
    _ = ctx;
    _ = set;
    @panic("TODO: exec.emitCsr");
}

/// Working NodeSet for the stack machine.
/// TODO: paged bitmap (node_bitmap directory or a flat []u64 sized to the
/// view's node count — the view is fixed for the whole run, so flat words
/// are simplest) + a count so emit_count/emit_exists are O(1) when already
/// tracked.
pub const NodeSet = struct {
    count: u32 = 0,
    // TODO: storage (suggested: words: []u64 over ctx arena).
};

comptime {
    _ = node_bitmap;
    _ = snapshot_iterators;
}
