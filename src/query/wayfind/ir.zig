//! Wayfind plan IR. Step layout and op
//! numbers are FROZEN within a major version; extensions may only append ops.
//!
//! A plan is a flat array of fixed-size `Step`s evaluated by a stack machine
//! over NodeSets. Pointer-free, extern layout: these bytes are also the
//! future C-ABI wire format, so a plan must be treated as hostile input —
//! `validate` is the trust boundary every non-comptime plan crosses before
//! execution (the comptime builder is exempt: its typestate cannot produce
//! an invalid plan).

const std = @import("std");

/// Sentinel for `Step.rel`: expand over every relation.
pub const ANY_RELATION: u16 = 0xFFFF;

/// Sentinel for `Hops.max`: unbounded closure (`out(rel)*`). Termination is
/// guaranteed by set semantics — a frontier can only grow until it covers
/// the node count.
pub const UNBOUNDED: u16 = 0xFFFF;

pub const Op = enum(u16) {
    /// Push the parameter set in slot `param`.
    seed_param = 0,
    /// Push the singleton set { `arg` }.
    seed_node = 1,
    /// Push the set of all live nodes.
    all_nodes = 2,
    /// Pop a set, push `{ v : hops.min <= level(v) <= hops.max }` where
    /// `level(v)` is the shortest `dir`/`rel` distance from the input set
    /// (input nodes have level 0). Normative corollaries:
    /// `{0..0}` is the identity; an input node re-reached in k>0
    /// hops keeps level 0 and appears only when min == 0; each node is
    /// expanded at most once (cost bound = termination proof).
    expand = 3,
    /// Pop two sets, push their union.
    set_union = 4,
    /// Pop two sets, push their intersection.
    set_intersect = 5,
    /// Pop two sets, push (lower ∖ top) — the set pushed FIRST minus the
    /// set pushed last, matching pipeline reading order (`... | - $x`).
    set_minus = 6,
    /// Pop a set, push the nodes whose `dir` degree satisfies `cmp arg`.
    filter_degree = 7,
    /// Terminals: pop the final set, produce the result, end the plan.
    /// Determinism guarantees are normative: ids sorted
    /// ascending; edges sorted by (source, destination, prop_row).
    emit_ids = 8,
    emit_count = 9,
    /// May short-circuit on the first member found.
    emit_exists = 10,
    /// Edges between nodes of the set (source AND destination inside),
    /// with their property rows — the columnar join key.
    emit_edges = 11,
    /// CSR of the induced subgraph: offsets span ALL node ids
    /// (non-members empty), targets keep original ids, members only.
    emit_csr = 12,

    // Values 13..15 are reserved for future extensions. A v1
    // validator rejects unknown ops — forward compatibility is explicit
    // failure, never misexecution.
};

pub const Direction = enum(u8) { out = 0, in = 1, both = 2 };

pub const Cmp = enum(u8) { lt = 0, le = 1, eq = 2, ge = 3, gt = 4 };

pub const Hops = extern struct {
    min: u16 = 1,
    max: u16 = 1,
};

/// One plan step. 16 bytes; operand fields are meaningful per-op (see Op
/// docs) and MUST be zero/default otherwise so plans compare and hash
/// structurally.
pub const Step = extern struct {
    op: Op,
    dir: Direction = .out,
    cmp: Cmp = .ge,
    rel: u16 = ANY_RELATION,
    param: u16 = 0,
    hops: Hops = .{},
    /// seed_node: the node id. filter_degree: the threshold.
    arg: u32 = 0,
};

pub const Plan = struct {
    steps: []const Step,
    /// Number of parameter slots the plan references (max slot + 1).
    param_count: u16,
};

/// Edge output row (`emit_edges`). `prop_row` is 0 when the graph has no
/// edge properties.
pub const EdgeRow = extern struct {
    source: u32,
    destination: u32,
    prop_row: u32,
};

pub const PlanError = error{
    /// A set/transform/terminal op found fewer operands than its arity.
    StackUnderflow,
    /// The plan ended with a non-empty stack or a non-terminal last step.
    MissingTerminal,
    /// A terminal op appeared before the last step.
    EarlyTerminal,
    /// `param` slot >= `param_count`.
    UnknownParam,
    /// hops.min > hops.max.
    InvalidHops,
    /// op/dir/cmp byte outside its enum range (hostile plan bytes).
    InvalidEnum,
    /// Operand field set for an op that does not use it.
    DirtyOperand,
};

/// Static validation — the trust boundary for every plan that did not come
/// from the comptime builder. Checks, in order: enum ranges (the bytes may
/// be hostile — use std.meta.intToEnum, never @enumFromInt), stack
/// discipline (sources +1, set ops -1, transforms 0, terminal -1 and last),
/// exactly one terminal as the final step, param slots < param_count,
/// hops.min <= hops.max, and operand cleanliness per op.
pub fn validate(plan: Plan) PlanError!void {
    _ = plan;
    @panic("TODO: ir.validate");
}

comptime {
    std.debug.assert(@sizeOf(Step) == 16);
    std.debug.assert(@sizeOf(EdgeRow) == 12);
    std.debug.assert(@sizeOf(Hops) == 4);
}
