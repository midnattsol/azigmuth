//! Accessor layer for edge-block payloads (DESIGN §5.3): traversal, search,
//! mutation, repair, and validation go through these functions instead of
//! addressing block fields directly, so the in-block layout can evolve (SoA,
//! compression, live-count sidecars) without touching the engine logic.

const types = @import("../core/types.zig");
const constants = @import("../core/constants.zig");

// ── Live count ───────────────────────────────────────────────────────

pub inline fn liveCountFwd(block: *const types.EdgeBlockFwd) u7 {
    return @intCast(@popCount(block.mask));
}

pub inline fn liveCountRev(block: *const types.EdgeBlockRev) u7 {
    return @intCast(@popCount(block.mask));
}

pub inline fn setLiveCountFwd(block: *types.EdgeBlockFwd, live_count: u7) void {
    block.mask = constants.denseMask(live_count);
}

pub inline fn setLiveCountRev(block: *types.EdgeBlockRev, live_count: u7) void {
    block.mask = constants.denseMask(live_count);
}

// ── Forward entry access ─────────────────────────────────────────────

pub inline fn fwdDestination(block: *const types.EdgeBlockFwd, slot: usize) u32 {
    return block.destinations[slot];
}

pub inline fn fwdRelation(block: *const types.EdgeBlockFwd, slot: usize) u16 {
    return block.relations[slot];
}

pub inline fn fwdFlags(block: *const types.EdgeBlockFwd, slot: usize) types.EdgeFlags {
    return @bitCast(block.flags[slot]);
}

pub inline fn setFwdEntry(block: *types.EdgeBlockFwd, slot: usize, destination: u32, relation: u16, flags: types.EdgeFlags) void {
    block.destinations[slot] = destination;
    block.relations[slot] = relation;
    block.flags[slot] = @bitCast(flags);
}

pub inline fn copyFwdEntry(destination_block: *types.EdgeBlockFwd, destination_slot: usize, source_block: *const types.EdgeBlockFwd, source_slot: usize) void {
    destination_block.destinations[destination_slot] = source_block.destinations[source_slot];
    destination_block.relations[destination_slot] = source_block.relations[source_slot];
    destination_block.flags[destination_slot] = source_block.flags[source_slot];
}

pub inline fn moveFwdEntry(block: *types.EdgeBlockFwd, destination_slot: usize, source_slot: usize) void {
    block.destinations[destination_slot] = block.destinations[source_slot];
    block.relations[destination_slot] = block.relations[source_slot];
    block.flags[destination_slot] = block.flags[source_slot];
}

/// Contiguous live destinations of a forward block (256 B max — 4 cache
/// lines). Stable while the block is published (RCU immutability).
pub inline fn fwdDestinationsView(block: *const types.EdgeBlockFwd, live_count: usize) []const u32 {
    return block.destinations[0..live_count];
}

// ── Reverse entry access ─────────────────────────────────────────────

pub inline fn revSource(block: *const types.EdgeBlockRev, slot: usize) u32 {
    return block.sources[slot];
}

pub inline fn setRevSource(block: *types.EdgeBlockRev, slot: usize, source_idx: u32) void {
    block.sources[slot] = source_idx;
}

pub inline fn copyRevEntry(destination_block: *types.EdgeBlockRev, destination_slot: usize, source_block: *const types.EdgeBlockRev, source_slot: usize) void {
    destination_block.sources[destination_slot] = source_block.sources[source_slot];
}

pub inline fn moveRevEntry(block: *types.EdgeBlockRev, destination_slot: usize, source_slot: usize) void {
    block.sources[destination_slot] = block.sources[source_slot];
}

// ── Bulk views (read-only) ───────────────────────────────────────────

/// Contiguous live source ids of a reverse block. Stable while the block is
/// published (RCU immutability).
pub inline fn revSourcesView(block: *const types.EdgeBlockRev, live_count: usize) []const u32 {
    return block.sources[0..live_count];
}
