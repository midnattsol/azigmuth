const common = @import("common.zig");
const block_shape = @import("block_shape.zig");
const adjacency_collect = @import("adjacency_collect.zig");
const ownership_sets = @import("ownership/sets.zig");
const ownership_report = @import("ownership/report.zig");
const std = @import("std");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");

pub const appendBlockShapeViolations = block_shape.appendBlockShapeViolations;
pub const appendContiguousBlocks = adjacency_collect.appendContiguousBlocks;
pub const DebugGroupSpan = adjacency_collect.DebugGroupSpan;
pub const spansOverlap = adjacency_collect.spansOverlap;
pub const collectAdjacencyBlocks = adjacency_collect.collectAdjacencyBlocks;

pub const buildFreeBlockSet = ownership_sets.buildFreeBlockSet;
pub const buildRetiredBlockSet = ownership_sets.buildRetiredBlockSet;
pub const buildFreeGroupSet = ownership_sets.buildFreeGroupSet;
pub const buildRetiredGroupSet = ownership_sets.buildRetiredGroupSet;
pub const markOwnedBlock = ownership_sets.markOwnedBlock;
pub const appendOwnershipAndShapeViolations = ownership_report.appendOwnershipAndShapeViolations;
