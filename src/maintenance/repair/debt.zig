//! Repair debt facade — policy and mechanics re-exports.

const mechanics = @import("debt/mechanics.zig");
const policy = @import("debt/policy.zig");

pub const RepairDebtAssessment = policy.RepairDebtAssessment;

pub const popRepairDebtBestEffort = mechanics.popRepairDebtBestEffort;
pub const queuedRepairCount = mechanics.queuedRepairCount;
pub const countNodesWithRepairFlag = mechanics.countNodesWithRepairFlag;
pub const findRepairDebtByFlag = mechanics.findRepairDebtByFlag;

pub const updateRepairDebt = policy.updateRepairDebt;
pub const updateRepairDebtAfterEdgeMutation = policy.updateRepairDebtAfterEdgeMutation;
pub const computeNeedsRepair = policy.computeNeedsRepair;
pub const assessPublishedRepairDebt = policy.assessPublishedRepairDebt;
pub const refreshPublishedRepairDebt = policy.refreshPublishedRepairDebt;
pub const updateRepairDebtSide = policy.updateRepairDebtSide;
