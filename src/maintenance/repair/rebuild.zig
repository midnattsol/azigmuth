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

pub const SortedRebuildResult = sorted_rebuild.SortedRebuildResult;
pub const sortedRebuildForward = sorted_rebuild.sortedRebuildForward;
pub const sortedRebuildReverse = sorted_rebuild.sortedRebuildReverse;

pub const countReverseSourceMatches = cleanup.countReverseSourceMatches;
pub const prepareReverseWithoutSource = cleanup.prepareReverseWithoutSource;

pub const repairForwardTombstonesWithReverseCleanup = tombstone_repair.repairForwardTombstonesWithReverseCleanup;
