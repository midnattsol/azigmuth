const common = @import("common.zig");
const pair = @import("pair_consistency.zig");
const layout = @import("layout_report.zig");
const repair_debt = @import("repair_debt_report.zig");

pub const runContainsTarget = pair.runContainsTarget;
pub const findSlotInRun = pair.findSlotInRun;
pub const adjacencyContains = pair.adjacencyContains;
pub const appendForwardEdgeIdViolations = pair.appendForwardEdgeIdViolations;
pub const validateForwardEdgeIdsFast = pair.validateForwardEdgeIdsFast;
pub const appendForwardConsistencyViolations = pair.appendForwardConsistencyViolations;
pub const appendReverseConsistencyViolations = pair.appendReverseConsistencyViolations;
pub const validateForwardConsistencyFast = pair.validateForwardConsistencyFast;
pub const validateForwardConsistencyInContiguousBlocks = pair.validateForwardConsistencyInContiguousBlocks;
pub const validateReverseConsistencyFast = pair.validateReverseConsistencyFast;
pub const validateReverseConsistencyInContiguousBlocks = pair.validateReverseConsistencyInContiguousBlocks;
pub const appendLayoutDebtViolations = layout.appendLayoutDebtViolations;
pub const appendRepairDebtViolations = repair_debt.appendRepairDebtViolations;
