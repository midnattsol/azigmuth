//! Local repair — compact adjacency blocks to restore occupancy thresholds.

const debt = @import("repair/debt.zig");
const rebuild = @import("repair/rebuild.zig");
const scheduler = @import("repair/scheduler.zig");

pub const updateRepairDebt = debt.updateRepairDebt;
pub const updateRepairDebtAfterEdgeMutation = debt.updateRepairDebtAfterEdgeMutation;
pub const updateRepairDebtSide = debt.updateRepairDebtSide;

pub const sortedRebuildForward = rebuild.sortedRebuildForward;
pub const sortedRebuildReverse = rebuild.sortedRebuildReverse;
pub const rebuildForwardAlive = rebuild.rebuildForwardAlive;
pub const rebuildReverseDrop = rebuild.rebuildReverseDrop;
pub const countReverseMatches = rebuild.countReverseMatches;
pub const prepareReverseDrop = rebuild.prepareReverseDrop;

pub const repairNodeSide = scheduler.repairNodeSide;
pub const repairNode = scheduler.repairNode;
pub const repairBudgeted = scheduler.repairBudgeted;
pub const flushRepairs = scheduler.flushRepairs;
