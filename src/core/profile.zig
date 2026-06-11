//! Comptime storage profiles. A profile fixes the page-directory geometry,
//! the reader-slot pool, and therefore both the fixed memory footprint of a
//! `Graph` instance and its structural capacity ceilings.
//!
//! Selection follows the `std.Options` pattern: the root module of the
//! consuming program may declare
//!
//!   pub const azigmuth_options: azigmuth.Options = .{ .profile = .embedded };
//!
//! and the library picks it up at comptime. Without a declaration the
//! `default` profile applies. One compilation = one profile; there is no
//! runtime dispatch and no per-call cost.

const std = @import("std");

/// Geometry of one lazy two-level page directory (see
/// `storage/radix_directory.zig`). `inline_pages` entries live inline in the
/// directory itself and cover the first pages with zero heap allocation; the
/// remaining `l1 × l2` pages hang off a lazily allocated root → leaf tree.
pub const DirDims = struct {
    inline_pages: usize,
    l1: usize,
    l2: usize,

    pub fn maxPages(comptime self: DirDims) usize {
        return self.inline_pages + self.l1 * self.l2;
    }
};

pub const Profile = struct {
    /// Directory geometry for the node-indexed pools (meta, published, hot,
    /// tiny slots, repair bitmaps). 256 entries per page.
    node_dir: DirDims,
    /// Directory geometry for edge-block pools (64 blocks per page).
    edge_block_dir: DirDims,
    /// Directory geometry for the grouped-run pool (128 groups per page).
    edge_group_dir: DirDims,
    /// Precise reader epoch slots (power of two). Readers beyond this fall
    /// into the conservative overflow path.
    reader_slots: usize,
    /// Tracked overflow reader tokens. `reader_slots + tracked_overflow`
    /// must be a power of two.
    tracked_overflow_readers: usize,
    /// Edges per adjacency block: 16, 32, or 64. Smaller blocks waste less
    /// memory on sparse graphs (a degree-9 node occupies a 128 B block at 16
    /// instead of 512 B at 64) at the cost of more blocks per high-degree
    /// node. The 75% occupancy floor scales with it (12/24/48).
    edges_per_block: u16,

    /// Large ceilings, lazy growth: ~2^31 edge blocks (≈137G edges),
    /// ~4.3G nodes. Fixed footprint stays small because directory levels
    /// are allocated on demand.
    pub const default: Profile = .{
        .node_dir = .{ .inline_pages = 4, .l1 = 4096, .l2 = 4096 },
        .edge_block_dir = .{ .inline_pages = 4, .l1 = 4096, .l2 = 8192 },
        .edge_group_dir = .{ .inline_pages = 4, .l1 = 4096, .l2 = 4096 },
        .reader_slots = 256,
        .tracked_overflow_readers = 256,
        .edges_per_block = 64,
    };

    /// Small fixed footprint and small ceilings for constrained targets:
    /// ~66K nodes, ~266K edges (16-edge blocks), 8 tracked readers.
    pub const embedded: Profile = .{
        .node_dir = .{ .inline_pages = 4, .l1 = 16, .l2 = 16 },
        .edge_block_dir = .{ .inline_pages = 4, .l1 = 16, .l2 = 16 },
        .edge_group_dir = .{ .inline_pages = 4, .l1 = 16, .l2 = 16 },
        .reader_slots = 8,
        .tracked_overflow_readers = 8,
        .edges_per_block = 16,
    };

    pub fn validate(comptime self: Profile) void {
        comptime {
            std.debug.assert(std.math.isPowerOfTwo(self.reader_slots));
            std.debug.assert(std.math.isPowerOfTwo(self.reader_slots + self.tracked_overflow_readers));
            std.debug.assert(self.edges_per_block == 16 or self.edges_per_block == 32 or self.edges_per_block == 64);
            std.debug.assert(self.node_dir.inline_pages >= 1);
            std.debug.assert(self.edge_block_dir.inline_pages >= 1);
            std.debug.assert(self.edge_group_dir.inline_pages >= 1);
        }
    }
};

/// Root-module override hook (`pub const azigmuth_options: Options = .{...}`).
pub const Options = struct {
    profile: Profile = Profile.default,
};

const root = @import("root");
const build_options = @import("azigmuth_options");

fn presetByName(comptime name: []const u8) Profile {
    if (std.mem.eql(u8, name, "embedded")) return Profile.embedded;
    if (std.mem.eql(u8, name, "default")) return Profile.default;
    @compileError("unknown azigmuth profile preset: " ++ name);
}

/// Resolution order:
///  1. `pub const azigmuth_options: Options` in the root module — full custom
///     profiles, but only visible in executable/library builds (`zig test`
///     compilations route `root` to the test runner).
///  2. The `azigmuth_options` build-option module (`-Dprofile=<preset>` when
///     consuming azigmuth through the package manager).
pub const active: Profile = blk: {
    if (@hasDecl(root, "azigmuth_options")) {
        const opts: Options = root.azigmuth_options;
        opts.profile.validate();
        break :blk opts.profile;
    }
    const preset = presetByName(build_options.profile_preset);
    preset.validate();
    break :blk preset;
};
