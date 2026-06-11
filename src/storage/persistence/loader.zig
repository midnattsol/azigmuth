//! Snapshot loader by copy (SKELETON: every body is a TODO).
//!
//! Reads a snapshot file and reconstructs a fully mutable live graph in the
//! heap. The validation ladder (header → table → length → checksums) lives
//! in `io.zig` and is shared with `frozen.zig` — this module adds the
//! materialization: restore pages, replay NodeRecords, push free lists,
//! restore counters. Epochs/readers/repair queues start fresh
//! (reconstructed, never persisted).
//!
//! Index sanity beyond checksums (a checksum proves integrity, not honesty:
//! a well-checksummed file can still claim block_count > the section can
//! hold, or a free index past the frontier) is cross-checked during
//! restore — every index read from the payload is bounds-checked against
//! the header counters before use.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const graph = @import("../../graph.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const page_ops = @import("../page_ops.zig");
const node_tiny = @import("../node/tiny.zig");
const format = @import("format.zig");
const io_mod = @import("io.zig");

// TODO: narrow (io_mod.ValidateError || error{CorruptIndex, OutOfMemory}).
pub const LoadError = anyerror;

/// Loads `<sub_path>` into a fresh, fully mutable graph. GraphOptions are
/// not a parameter: multigraph / edge_properties come from the header flags.
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) LoadError!graph.Graph {
    _ = allocator;
    _ = io;
    _ = dir;
    _ = sub_path;
    // TODO orchestration:
    //   1. open file, stat for the real length.
    //   2. validation ladder (io_mod): read HEADER_BYTES → parseHeader →
    //      read table → parseSectionTable → checkSectionsAgainstFileLen.
    //   3. var g = try graph.Graph.initWithOptions(allocator, .{
    //          .multigraph = header.flags.multigraph,
    //          .edge_properties = header.flags.edge_properties });
    //      errdefer g.deinit();
    //   4. per section (in table order): read payload →
    //      io_mod.verifySectionChecksum → dispatch to the restore* helper.
    //      Page sections first (they only need ensure*Capacity + memcpy),
    //      then node records (they reference block/tiny indices and can now
    //      be bounds-checked), then free lists.
    //   5. restore the header counters into &g.graph (node_count,
    //      edge_count, frontiers, prop_row_count).
    //   6. debug builds: run the existing validate machinery as a final net.
    @panic("TODO: load");
}

// ── Restore helpers (checksums already verified; indices still hostile) ──

/// Copies a raw page section back into freshly ensured engine pages.
/// `ensure*Capacity` + page-by-page @memcpy; the section family decides
/// which directory and page shape.
pub fn restoreBlockPages(core: *graph_core.GraphCore, payload: []const u8, comptime side: adjacency.AdjSide) LoadError!void {
    _ = core;
    _ = payload;
    _ = side;
    @panic("TODO: restoreBlockPages");
}

pub fn restoreLivePages(core: *graph_core.GraphCore, payload: []const u8, comptime side: adjacency.AdjSide) LoadError!void {
    _ = core;
    _ = payload;
    _ = side;
    @panic("TODO: restoreLivePages");
}

pub fn restoreEdgeIdPages(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    _ = core;
    _ = payload;
    @panic("TODO: restoreEdgeIdPages");
}

pub fn restorePropRowPages(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    _ = core;
    _ = payload;
    @panic("TODO: restorePropRowPages");
}

pub fn restoreGroupPages(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    _ = core;
    _ = payload;
    @panic("TODO: restoreGroupPages");
}

pub fn restoreTinyPages(core: *graph_core.GraphCore, payload: []const u8, comptime side: adjacency.AdjSide) LoadError!void {
    _ = core;
    _ = payload;
    _ = side;
    @panic("TODO: restoreTinyPages");
}

/// Replays one NodeRecord into the live node pools: NodeMeta (degrees,
/// flags, fwd/rev_index = 0, version 0), NodePublished (slot 0 = the
/// persisted SideAdj, sorted bits), NodeHot (next_local_edge_id, claims
/// released). Every block/group/tiny index inside the record is
/// bounds-checked against the header counters (CorruptIndex).
pub fn restoreNodeRecord(core: *graph_core.GraphCore, node_index: u32, record: format.NodeRecord, header: format.FileHeader) LoadError!void {
    _ = core;
    _ = node_index;
    _ = record;
    _ = header;
    @panic("TODO: restoreNodeRecord");
}

/// Pushes a persisted free list back onto its lock-free stack. Indices are
/// bounds-checked against the matching frontier counter first.
pub fn restoreFreeList(core: *graph_core.GraphCore, id: format.SectionId, payload: []const u8, header: format.FileHeader) LoadError!void {
    _ = core;
    _ = id;
    _ = payload;
    _ = header;
    // TODO: u32 entries → page_ops.freeBlock / freeTinySlot /
    // freePropRow; FreeGroupSpan entries → page_ops.freeGroupSpan.
    @panic("TODO: restoreFreeList");
}

comptime {
    _ = constants;
    _ = types;
    _ = page_ops;
    _ = node_tiny;
    _ = io_mod;
}
