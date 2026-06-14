//! Adjacency rebuild — re-exports from sub-modules.

const claims = @import("claims.zig");
const tombstones = @import("tombstones.zig");
const sorted_rebuild = @import("sorted_rebuild.zig");
const cleanup = @import("cleanup.zig");
const tombstone_repair = @import("tombstone_repair.zig");

pub const beginWriter = claims.beginWriter;
pub const claimNodeForPublish = claims.claimNodeForPublish;
pub const releaseNodeForPublish = claims.releaseNodeForPublish;

pub const hasAnyTombstone = tombstones.hasAnyTombstone;
pub const collectForwardTombstones = tombstones.collectForwardTombstones;

pub const SortedRebuildResult = sorted_rebuild.SortedRebuildResult;
pub const sortedRebuildForward = sorted_rebuild.sortedRebuildForward;
pub const sortedRebuildReverse = sorted_rebuild.sortedRebuildReverse;

pub const rebuildForwardAlive = cleanup.rebuildForwardAlive;
pub const rebuildReverseDrop = cleanup.rebuildReverseDrop;
pub const countReverseMatches = cleanup.countReverseMatches;
pub const prepareReverseDrop = cleanup.prepareReverseDrop;

pub const compactForwardTombstones = tombstone_repair.compactForwardTombstones;
