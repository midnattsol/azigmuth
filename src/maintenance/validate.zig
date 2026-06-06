//! Structural validation of graph invariants — public facade.
//!
//! Two levels: `validate` (fast, no allocation) and `debugValidate` (exhaustive, allocating).

const common = @import("validate/common.zig");
const shape = @import("validate/shape.zig");
const sums = @import("validate/sums.zig");
const stacks = @import("validate/stacks.zig");
const ownership = @import("validate/ownership.zig");
const run_search = @import("validate/run_search.zig");
const consistency = @import("validate/consistency.zig");
const violations = @import("validate/violations.zig");

// ── Re-exports from common.zig ──────────────────────────────────────────
pub const Side = common.Side;
pub const StackKindFast = common.StackKindFast;
pub const MAX_TRACKED_BLOCKS = common.MAX_TRACKED_BLOCKS;
pub const TRACKED_BLOCK_BITMAP_WORDS = common.TRACKED_BLOCK_BITMAP_WORDS;
pub const MAX_TRACKED_GROUPS = common.MAX_TRACKED_GROUPS;
pub const TRACKED_GROUP_BITMAP_WORDS = common.TRACKED_GROUP_BITMAP_WORDS;
pub const TraversedBlock = common.TraversedBlock;
pub const bitmapSet = common.bitmapSet;
pub const bitmapIsSet = common.bitmapIsSet;
pub const readerEnter = common.readerEnter;
pub const readerExit = common.readerExit;
pub const blockCount = common.blockCount;
pub const groupCount = common.groupCount;
pub const firstBlock = common.firstBlock;
pub const firstGroup = common.firstGroup;
pub const allocatedBlockCount = common.allocatedBlockCount;
pub const blockExists = common.blockExists;
pub const blockMask = common.blockMask;
pub const blockKey = common.blockKey;
pub const needsRepairFlag = common.needsRepairFlag;

// ── Re-exports from shape.zig ──────────────────────────────────────────
pub const validateBlockDense = shape.validateBlockDense;
pub const validateDenseInContiguousBlocks = shape.validateDenseInContiguousBlocks;
pub const validateDenseInGroupChain = shape.validateDenseInGroupChain;
pub const validateDenseMasks = shape.validateDenseMasks;
pub const validateBlockShapeFast = shape.validateBlockShapeFast;
pub const validateContiguousBlocksFast = shape.validateContiguousBlocksFast;
pub const validateGroupChainFast = shape.validateGroupChainFast;
pub const validateAdjacencyBlocksFast = shape.validateAdjacencyBlocksFast;
pub const validateOccupancyFast = shape.validateOccupancyFast;

// ── Re-exports from sums.zig ───────────────────────────────────────────
pub const sumBlockLive = sums.sumBlockLive;
pub const sumContiguousBlocks = sums.sumContiguousBlocks;
pub const sumGroupChain = sums.sumGroupChain;
pub const sumAdjacency = sums.sumAdjacency;
pub const countVisibleEntriesInBlock = sums.countVisibleEntriesInBlock;
pub const sumVisibleAdjacency = sums.sumVisibleAdjacency;

// ── Re-exports from stacks.zig ─────────────────────────────────────────
pub const blockStackHeadIndex = stacks.blockStackHeadIndex;
pub const blockMetaNextFast = stacks.blockMetaNextFast;
pub const populateStackBitmapFast = stacks.populateStackBitmapFast;
pub const groupStackHeadIndexFast = stacks.groupStackHeadIndexFast;
pub const groupMetaNextFast = stacks.groupMetaNextFast;
pub const populateGroupStackBitmapFast = stacks.populateGroupStackBitmapFast;

// ── Re-exports from ownership.zig ──────────────────────────────────────
pub const validateOwnedBlockFast = ownership.validateOwnedBlockFast;
pub const validateAdjacencyOwnershipAndLayoutFast = ownership.validateAdjacencyOwnershipAndLayoutFast;
pub const validateRepairDebtFast = ownership.validateRepairDebtFast;

// ── Re-exports from consistency.zig ────────────────────────────────────
pub const runContainsTarget = run_search.runContainsTarget;
pub const findSlotInRun = run_search.findSlotInRun;
pub const adjacencyContains = run_search.adjacencyContains;
pub const appendForwardConsistencyViolations = consistency.appendForwardConsistencyViolations;
pub const appendReverseConsistencyViolations = consistency.appendReverseConsistencyViolations;
pub const appendRepairDebtViolations = consistency.appendRepairDebtViolations;
pub const appendLayoutDebtViolations = consistency.appendLayoutDebtViolations;
pub const validateForwardConsistencyFast = consistency.validateForwardConsistencyFast;
pub const validateForwardConsistencyInContiguousBlocks = consistency.validateForwardConsistencyInContiguousBlocks;
pub const validateReverseConsistencyFast = consistency.validateReverseConsistencyFast;
pub const validateReverseConsistencyInContiguousBlocks = consistency.validateReverseConsistencyInContiguousBlocks;

// ── Re-exports from violations.zig ─────────────────────────────────────
pub const DebugGroupSpan = violations.DebugGroupSpan;
pub const forwardHasTombstone = common.forwardHasTombstone;
pub const appendBlockShapeViolations = violations.appendBlockShapeViolations;
pub const appendContiguousBlocks = violations.appendContiguousBlocks;
pub const spansOverlap = violations.spansOverlap;
pub const collectAdjacencyBlocks = violations.collectAdjacencyBlocks;
pub const buildFreeBlockSet = violations.buildFreeBlockSet;
pub const buildRetiredBlockSet = violations.buildRetiredBlockSet;
pub const buildFreeGroupSet = violations.buildFreeGroupSet;
pub const buildRetiredGroupSet = violations.buildRetiredGroupSet;
pub const markOwnedBlock = violations.markOwnedBlock;
pub const appendOwnershipAndShapeViolations = violations.appendOwnershipAndShapeViolations;

// ── Entry points ───────────────────────────────────────────────────────
pub const validate = @import("validate/fast.zig").validate;
pub const debugValidate = @import("validate/debug.zig").debugValidate;
