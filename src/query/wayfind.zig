//! Wayfind — the azigmuth query language.
//! One import point for the language stack; the pieces live in `wayfind/`:
//!
//!   - `ir`      — the plan: fixed-size steps (the frozen wire format),
//!     stack-machine semantics, `validate` as the trust boundary for
//!     non-comptime plans.
//!   - `builder` — comptime fluent surface; typestate replaces validation.
//!   - `exec`    — the executor over a `CapturedGraphView`.

pub const ir = @import("wayfind/ir.zig");
pub const builder = @import("wayfind/builder.zig");
pub const exec = @import("wayfind/exec.zig");

/// Wayfind language/IR version. Step layout, op numbers
/// and grammar are frozen within a major version; extensions only append.
pub const VERSION: u16 = 1;

pub const Query = builder.Query;
pub const Plan = ir.Plan;
pub const Step = ir.Step;
pub const Params = exec.Params;
pub const Result = exec.Result;
pub const run = exec.run;
pub const validate = ir.validate;
