const std = @import("std");
const types = @import("types.zig");
const profile = @import("profile.zig");

/// Active comptime storage profile (root-module `azigmuth_options` override or
/// `Profile.default`). All capacity ceilings below derive from it.
pub const active_profile: profile.Profile = profile.active;

/// Entries per page — chosen to fit in common cache sizes.
pub const NODES_PER_PAGE: u32 = 256; // 256 × 64 B = 16 KB.
pub const EDGE_BLOCKS_PER_PAGE: u32 = 64; // 64 blocks × (8 B × edges_per_block) per page (32 KB at the default 64-edge blocks); live counts: one 64 B sidecar page per block page.
pub const EDGE_SEGMENTS_PER_PAGE: u32 = 128; // 128 × 8 B = 1 KB.

/// Property-row reclamation entries per page (edge_properties mode).
pub const PROP_ROWS_PER_PAGE: u32 = 256;

/// Sentinel value marking the end of an EdgeBlockSegment chain.
pub const END_OF_CHAIN: u32 = 0xFFFF_FFFF;

/// Minimum occupancy per non-tail block (75% of the block capacity).
pub const MIN_OCCUPANCY: u7 = (EDGES_PER_BLOCK / 4) * 3;

/// Maximum number of segments per node before repair is required.
pub const MAX_SEGMENTS_PER_NODE: u16 = 4;

/// Maximum number of edges per block (16/32/64, fixed by the profile).
pub const EDGES_PER_BLOCK: u7 = @intCast(active_profile.edges_per_block);

/// Lazy page-directory geometry (see storage/radix_directory.zig). The inline
/// slots cover the first pages with zero heap cost; the root → leaf tree is
/// allocated on demand, so these ceilings cost nothing until used.
pub const NODE_DIR = active_profile.node_dir;
pub const EDGE_BLOCK_DIR = active_profile.edge_block_dir;
pub const EDGE_SEGMENT_DIR = active_profile.edge_segment_dir;

pub const MAX_NODE_PAGES: usize = NODE_DIR.maxPages();
pub const MAX_EDGE_BLOCK_PAGES: usize = EDGE_BLOCK_DIR.maxPages();
pub const MAX_EDGE_SEGMENT_PAGES: usize = EDGE_SEGMENT_DIR.maxPages();

/// Total edge-block capacity of one side pool (global, u32-indexed).
pub const MAX_TOTAL_BLOCKS_PER_POOL: u64 = @as(u64, MAX_EDGE_BLOCK_PAGES) * EDGE_BLOCKS_PER_PAGE;

/// Maximum number of blocks a single side (one node, one direction) can own.
/// Bounded by the pool capacity and by the published `u32` degree range:
/// block_count × 64 must fit in u32, and the tiny-mode tag reserves the top
/// bit of `SideAdj.block_count`.
pub const MAX_BLOCKS_PER_SIDE: u32 = @min(MAX_TOTAL_BLOCKS_PER_POOL, (1 << 26) - 1);

/// Maximum number of edges per side per node.
pub const MAX_DEGREE_PER_SIDE: u32 = MAX_BLOCKS_PER_SIDE * EDGES_PER_BLOCK;

/// Maximum number of simultaneously active reader critical sections tracked
/// with precise epochs. Overflow readers fall back to conservative reclamation.
pub const MAX_READER_SLOTS: usize = active_profile.reader_slots;
pub const MAX_TRACKED_OVERFLOW_READERS: usize = active_profile.tracked_overflow_readers;

comptime {
    std.debug.assert(@sizeOf(types.EdgeBlockFwd) == 8 * @as(usize, EDGES_PER_BLOCK));
    std.debug.assert(@alignOf(types.EdgeBlockFwd) == 64);
    std.debug.assert(@sizeOf(types.EdgeBlockRev) == 4 * @as(usize, EDGES_PER_BLOCK));
    std.debug.assert(@alignOf(types.EdgeBlockRev) == 64);
    // Tiny sides must always promote into a single block.
    std.debug.assert(EDGES_PER_BLOCK >= 16);
    std.debug.assert(@as(u32, MIN_OCCUPANCY) * 4 == @as(u32, EDGES_PER_BLOCK) * 3);
    std.debug.assert(@sizeOf(types.EdgeBlockSegment) == 8);
    std.debug.assert(@sizeOf(types.NodeAdj) == 36);
    std.debug.assert(@sizeOf(types.SideAdj) == 16);
    std.debug.assert(@sizeOf(types.NodePublicationState) == 8);
    std.debug.assert(@bitSizeOf(types.NodePublicationState) == 64);

    // Structural index spaces must stay clear of their u32 sentinels and tags:
    // block/segment/node indices below END_OF_CHAIN, per-side block counts below
    // the tiny-mode tag bit, per-side degrees representable in u32.
    std.debug.assert(MAX_TOTAL_BLOCKS_PER_POOL < END_OF_CHAIN);
    std.debug.assert(@as(u64, MAX_EDGE_SEGMENT_PAGES) * EDGE_SEGMENTS_PER_PAGE < END_OF_CHAIN);
    std.debug.assert(@as(u64, MAX_NODE_PAGES) * NODES_PER_PAGE >= NODES_PER_PAGE);
    std.debug.assert(MAX_BLOCKS_PER_SIDE < 0x8000_0000); // tiny-mode tag bit
    std.debug.assert(@as(u64, MAX_BLOCKS_PER_SIDE) * EDGES_PER_BLOCK <= std.math.maxInt(u32));
}
