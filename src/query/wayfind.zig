//! Wayfind — the public facade for the azigmuth query language.
//! The implementation lives in `wayfind/`, but only the stable surface below is
//! exported from `az.Wayfind`:
//!
//!   - `Query` — comptime fluent builder; typestate replaces validation.
//!   - `Plan` / `Step` — fixed-size IR and frozen wire layout.
//!   - `parse` / `Parsed` — textual frontend; parses one pipeline string into a
//!     validated runtime plan.
//!   - `Params` / `Result` — query inputs and owned outputs.
//!
//! Execution is through `ReadSnapshot.wayfind`; the low-level executor over the
//! internal captured snapshot view is intentionally not part of this facade.

const ir = @import("wayfind/ir.zig");
const builder = @import("wayfind/builder.zig");
const exec = @import("wayfind/exec.zig");
const parser = @import("wayfind/parser.zig");

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
pub const validate = ir.validate;
pub const parse = parser.parse;
pub const Parsed = parser.Parsed;
pub const RelationBinding = parser.RelationBinding;
pub const ParseError = parser.ParseError;
