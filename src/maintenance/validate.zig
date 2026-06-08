//! Structural validation of graph invariants — public facade.
//!
//! Two levels: `validate` (fast, no allocation) and `debugValidate` (exhaustive, allocating).

// ── Entry points ───────────────────────────────────────────────────────
pub const validate = @import("validate/fast.zig").validate;
pub const debugValidate = @import("validate/debug.zig").debugValidate;
pub const debugValidateSnapshot = @import("validate/debug.zig").debugValidateSnapshot;
pub const validateSnapshot = @import("validate/snapshot_fast.zig").validateSnapshot;
