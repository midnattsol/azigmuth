const std = @import("std");
const types = @import("types.zig");

/// Entries per page — chosen to fit in common cache sizes.
pub const NODES_PER_PAGE: u32 = 256; // 256 × 64 B = 16 KB.
pub const EDGE_BLOCKS_PER_PAGE: u32 = 64; // 64 × 520 B ≈ 33 KB — fits in L1 cache.
pub const EDGE_GROUPS_PER_PAGE: u32 = 128; // 128 × 12 B = 1536 B.

/// Sentinel value marking the end of an EdgeBlockGroup chain.
pub const END_OF_CHAIN: u32 = 0xFFFF_FFFF;

/// Compute the occupancy mask for a given live count. Handles the
/// edge cases live_count == 0 (mask = 0) and live_count == 64
/// (mask = 0xFFFF_FFFF_FFFF_FFFF) which would be UB with a bare shift.
pub fn denseMask(live_count: u7) u64 {
    if (live_count == 0) return 0;
    if (live_count == 64) return 0xFFFF_FFFF_FFFF_FFFF;
    return (@as(u64, 1) << @as(u6, @intCast(live_count))) - 1;
}

/// Occupancy mask for a fully-saturated edge block (all 64 slots occupied).
pub const FULL_BLOCK_MASK: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Minimum occupancy per non-tail block (75% of 64).
pub const MIN_OCCUPANCY: u6 = 48;

/// Maximum number of groups per node before repair is required.
pub const MAX_GROUPS_PER_NODE: u16 = 4;

/// Sentinel stored in NodeBuffer.degree_* when the node has 65535 or more
/// edges on that side.  outDegree / inDegree fall back to an O(B) scan.
pub const DEGREE_OVERFLOW: u16 = 0xFFFF;

/// Maximum page directory sizes for atomically-published storage pages.
/// These keep page lookup lock-free while preserving stable page addresses.
pub const MAX_NODE_PAGES: usize = 4096;
pub const MAX_EDGE_BLOCK_PAGES: usize = 4096;
pub const MAX_EDGE_GROUP_PAGES: usize = 4096;

/// Maximum number of simultaneously active reader critical sections tracked
/// with precise epochs. Overflow readers fall back to conservative reclamation.
pub const MAX_READER_SLOTS: usize = 256;

/// Retired blocks tracked for validation/reclamation debug views. Runtime
/// reclamation uses lock-free retired/free stacks.
pub const MAX_TRACKED_RETIRED_BLOCKS: usize = 16;

comptime {
    std.debug.assert(@sizeOf(types.NodeBuffer) == 64);
    std.debug.assert(@sizeOf(types.EdgeBlockFwd) == 520);
    std.debug.assert(@sizeOf(types.EdgeBlockRev) == 264);
    std.debug.assert(@sizeOf(types.EdgeBlockGroup) == 12);
}
