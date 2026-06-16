//! Wayfind — the azigmuth query language.
//! One import point for the language stack; the pieces live in `wayfind/`:
//!
//!   - `ir`      — the plan: fixed-size steps (the frozen wire format),
//!     stack-machine semantics, `validate` as the trust boundary for
//!     non-comptime plans.
//!   - `builder` — comptime fluent surface; typestate replaces validation.
//!   - `exec`    — the executor over a `CapturedGraphView`.
//!   - `parser`  — textual front-end; parses one pipeline string into a
//!     validated runtime plan (1:1 with the IR, no rewriting).

pub const ir = @import("wayfind/ir.zig");
pub const builder = @import("wayfind/builder.zig");
pub const exec = @import("wayfind/exec.zig");
pub const parser = @import("wayfind/parser.zig");

/// Wayfind language/IR version. Step layout, op numbers
/// and grammar are frozen within a major version; extensions only append.
pub const VERSION: u16 = 1;

pub const Query = builder.Query;
pub const ANY_RELATION = ir.ANY_RELATION;
pub const UNBOUNDED = ir.UNBOUNDED;
pub const Plan = ir.Plan;
pub const Step = ir.Step;
pub const Op = ir.Op;
pub const Direction = ir.Direction;
pub const Cmp = ir.Cmp;
pub const Hops = ir.Hops;
pub const EdgeRow = ir.EdgeRow;
pub const PlanError = ir.PlanError;
pub const Params = exec.Params;
pub const Result = exec.Result;
pub const ExecError = exec.ExecError;
pub const run = exec.run;
pub const validate = ir.validate;
pub const parse = parser.parse;
pub const Parsed = parser.Parsed;
pub const RelationBinding = parser.RelationBinding;
pub const ParseError = parser.ParseError;
