//!
//! This module defines the file layout, the compatibility contract, and the
//! pure helpers (size math, offsets, checksums, validation) that both a
//! writer and a loader need. It deliberately contains NO I/O and NO mmap
//! code: those live in the sibling writer/loader/frozen modules, built on top of this.
//!
//! ## Layout
//!
//! Little-endian, pointer-free (indices, never addresses), every section
//! 64-byte aligned so block sections can be handed to the engine — or to an
//! mmap — without copying:
//!
//! ```
//! offset 0      FileHeader            (fixed HEADER_BYTES budget, checksummed)
//! offset 512    [MAX_SECTIONS]SectionDescriptor   (fixed table)
//! ...           section payloads, in table order, each 64-byte aligned
//! ```
//!
//! ## What is persisted vs reconstructed
//!
//! Persisted:
//!  - one canonical `NodeRecord` per node (published sides normalized out of
//!    the RCU double-buffers: only the active slot survives a save),
//!  - the raw storage pages for edge blocks, live-count sidecars, edge-id /
//!    property-row sidecars (when enabled), grouped-run descriptors, and
//!    tiny slots — exactly the engine's in-memory page layout,
//!  - the free lists (cheap u32 index sections), so the loader does not need
//!    an O(E) ownership sweep to rediscover reusable storage.
//!
//! Reconstructed at load (never persisted): page directories, BlockMeta
//! stack metadata, retired stacks (must be empty — see save contract),
//! reader/epoch state, repair queues (the authoritative debt source is the
//! `needs_repair_*` bits inside each NodeRecord).
//!
//! ## Save contract (for the writer)
//!
//! The graph must be quiesced: no concurrent readers, writers, or repairers
//! (same precondition as `deinitChecked`). The writer MUST run
//! `reclaimRetired()` first so every retired block/group/tiny-slot/row has
//! drained into the free structures (and frontier rollback has trimmed the
//! pool); retired state is not representable in the file. Sides are written
//! normalized: per node, the published `SideAdj`, degree, and sorted bit of
//! each direction — staging slots and the RCU `version` counter are not
//! persisted (a loaded graph starts with `fwd_index = rev_index = 0`,
//! version 0).
//!
//! ## Load contract
//!
//! 1. Read HEADER_BYTES + `validateHeader` (magic, version, format params vs
//!    the running comptime profile — an `edges_per_block` mismatch is a hard
//!    error, the block byte layout differs).
//! 2. Read the section table; `validateSectionTable` against the header;
//!    verify per-section checksums (eagerly, or lazily per section).
//! 3. Materialize storage: copy (or, later, map) the page sections; rebuild
//!    the page directories pointing at them; replay each NodeRecord into
//!    `NodeMeta`/`NodePublished`/`NodeHot`; push the free-list sections onto
//!    the lock-free stacks; restore the header counters.
//!
//! Zero-copy note for the frozen mmap reader: the page sections (blocks,
//! sidecars, groups, tiny) are the bulk of the file and keep the engine's
//! exact page layout, so a read-only graph can point its directories
//! straight into the mapping. NodeRecords are intentionally NOT the
//! in-memory node layout — they expand at load (O(node_count), tiny next to
//! edge storage) into the mutable node pools, because `NodeMeta` words are
//! mutated through atomics and must live in private memory anyway.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../page_ops.zig");
const node_tiny = @import("../node/tiny.zig");
const node_hot_layout = @import("../node/hot_layout.zig");
const tiny_config = @import("../../core/tiny_config.zig");

/// "AZMTHRB1" — RB-CSR graph file, format major 1.
pub const MAGIC: u64 = 0x3142_5248_544D_5A41;

pub const FORMAT_VERSION_MAJOR: u16 = 1;
pub const FORMAT_VERSION_MINOR: u16 = 0;

/// Fixed byte budget reserved for the header at offset 0. The header struct
/// is smaller; the slack is zero-filled and covered by the header checksum,
/// leaving room for minor-version additions without moving the section table.
pub const HEADER_BYTES: usize = 512;

/// Section payload alignment. Matches the edge-block alignment so block
/// sections are usable in place.
pub const SECTION_ALIGN: usize = 64;

/// Every section the format knows about. Optional sections (multigraph /
/// edge_properties sidecars) stay in the table with `byte_len == 0` when
/// their feature is disabled, so the table layout is fixed.
pub const SectionId = enum(u16) {
    /// One canonical `NodeRecord` per node (`node_count` entries).
    node_records = 0,
    /// Raw `EdgeBlockFwd` pages: `blockPages(block_fwd_count)` pages.
    blocks_fwd = 1,
    /// Raw `EdgeBlockRev` pages.
    blocks_rev = 2,
    /// Forward live-count sidecar: one u8 per block slot, page-for-page.
    live_fwd = 3,
    /// Reverse live-count sidecar.
    live_rev = 4,
    /// `EdgeBlockFwdIds` pages (present iff `multigraph`).
    edge_ids_fwd = 5,
    /// `EdgeBlockFwdProps` pages (present iff `edge_properties`).
    prop_rows_fwd = 6,
    /// `EdgeBlockGroup` pages.
    groups = 7,
    /// `TinyFwdSlot` pages.
    tiny_fwd = 8,
    /// `TinyRevSlot` pages.
    tiny_rev = 9,
    /// Free forward block indices (u32 each; drain order is irrelevant).
    free_blocks_fwd = 10,
    /// Free reverse block indices.
    free_blocks_rev = 11,
    /// Free grouped-run spans: `FreeGroupSpan` entries.
    free_group_spans = 12,
    /// Free tiny forward slot indices (u32 each).
    free_tiny_fwd = 13,
    /// Free tiny reverse slot indices.
    free_tiny_rev = 14,
    /// Free property row ids (u32 each; present iff `edge_properties`).
    free_prop_rows = 15,
};

pub const MAX_SECTIONS: usize = 16;

/// Offset of the fixed section table (immediately after the header budget).
pub const SECTION_TABLE_OFFSET: usize = HEADER_BYTES;
pub const SECTION_TABLE_BYTES: usize = MAX_SECTIONS * @sizeOf(SectionDescriptor);

/// First byte where section payloads may start.
pub const PAYLOAD_BASE_OFFSET: usize = alignForward(SECTION_TABLE_OFFSET + SECTION_TABLE_BYTES, SECTION_ALIGN);

/// Comptime-profile parameters baked into the storage layout. A file is
/// loadable only by a build whose parameters match exactly: they change the
/// byte layout of pages (`edges_per_block`) or the meaning of indices.
pub const FormatParams = extern struct {
    edges_per_block: u16,
    nodes_per_page: u16,
    edge_blocks_per_page: u16,
    edge_groups_per_page: u16,
    tiny_fwd_cap_simple: u8,
    tiny_fwd_cap_multi: u8,
    tiny_rev_cap: u8,
    _reserved: u8 = 0,

    pub fn current() FormatParams {
        return .{
            .edges_per_block = constants.EDGES_PER_BLOCK,
            .nodes_per_page = @intCast(constants.NODES_PER_PAGE),
            .edge_blocks_per_page = @intCast(constants.EDGE_BLOCKS_PER_PAGE),
            .edge_groups_per_page = @intCast(constants.EDGE_GROUPS_PER_PAGE),
            .tiny_fwd_cap_simple = tiny_config.TINY_FWD_CAP_SIMPLE,
            .tiny_fwd_cap_multi = tiny_config.TINY_FWD_CAP_MULTI,
            .tiny_rev_cap = tiny_config.TINY_REV_CAP,
        };
    }

    pub fn matchesCurrentBuild(self: FormatParams) bool {
        const build_params = current();
        return std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&build_params));
    }
};

pub const GraphFlags = packed struct(u16) {
    multigraph: bool = false,
    edge_properties: bool = false,
    _reserved: u14 = 0,
};

/// Fixed-size file header at offset 0. `header_checksum` covers the entire
/// HEADER_BYTES budget with this field treated as zero; section payloads are
/// covered by per-section checksums instead, so a loader can verify lazily,
/// section by section.
pub const FileHeader = extern struct {
    magic: u64,
    version_major: u16,
    version_minor: u16,
    flags: GraphFlags,
    section_count: u16,
    params: FormatParams,

    /// Engine counters, restored verbatim on load.
    node_count: u64,
    edge_count: u64,
    block_fwd_count: u32,
    block_rev_count: u32,
    group_count: u32,
    tiny_fwd_count: u32,
    tiny_rev_count: u32,
    prop_row_count: u32,

    header_checksum: u64,

    pub fn init(core: *const graph_core.GraphCore) FileHeader {
        return .{
            .magic = MAGIC,
            .version_major = FORMAT_VERSION_MAJOR,
            .version_minor = FORMAT_VERSION_MINOR,
            .flags = .{
                .multigraph = core.multigraph_enabled,
                .edge_properties = core.edge_properties_enabled,
            },
            .section_count = MAX_SECTIONS,
            .params = FormatParams.current(),
            .node_count = core.publishedNodeCount(),
            .edge_count = core.edge_count.load(.acquire),
            .block_fwd_count = core.loadBlockFwdCount(),
            .block_rev_count = core.loadBlockRevCount(),
            .group_count = core.loadGroupCount(),
            .tiny_fwd_count = core.loadTinyFwdCount(),
            .tiny_rev_count = core.loadTinyRevCount(),
            .prop_row_count = core.loadPropRowCount(),
            .header_checksum = 0,
        };
    }
};

pub const HeaderError = error{
    BadMagic,
    UnsupportedVersion,
    IncompatibleFormatParams,
    CorruptHeader,
};

/// Validates everything a loader must check before trusting any offset.
/// `raw_header_block` is the full HEADER_BYTES region as read from the file.
pub fn validateHeader(header: FileHeader, raw_header_block: []const u8) HeaderError!void {
    if (header.magic != MAGIC) return error.BadMagic;
    if (header.version_major != FORMAT_VERSION_MAJOR) return error.UnsupportedVersion;
    if (!header.params.matchesCurrentBuild()) return error.IncompatibleFormatParams;
    if (header.section_count != MAX_SECTIONS) return error.CorruptHeader;
    if (raw_header_block.len != HEADER_BYTES) return error.CorruptHeader;
    if (headerChecksum(raw_header_block) != header.header_checksum) return error.CorruptHeader;
}

/// One section-table entry. `byte_len == 0` marks an absent optional
/// section; `entry_count` is the logical element count (pages for page
/// sections, records/indices for the rest) so a loader can cross-check
/// sizes without knowing element layouts.
pub const SectionDescriptor = extern struct {
    id: u16,
    _reserved: u16 = 0,
    entry_count: u32,
    file_offset: u64,
    byte_len: u64,
    checksum: u64,
};

/// Canonical persisted node state: the published view, normalized out of the
/// RCU double-buffers. 48 bytes. On load this expands into `NodeMeta`
/// (degrees/flags, indexes 0, version 0), `NodePublished` (slot 0 = the
/// persisted side, sorted bits as stored) and `NodeHot`
/// (`next_local_edge_id`; claims start released).
pub const NodeRecord = extern struct {
    fwd: types.SideAdj,
    rev: types.SideAdj,
    degree_fwd: u32,
    degree_rev: u32,
    next_local_edge_id: u32,
    flags: NodeRecordFlags,
    _reserved: u16 = 0,

    pub const NodeRecordFlags = packed struct(u16) {
        removed: bool = false,
        needs_repair_fwd: bool = false,
        needs_repair_rev: bool = false,
        fwd_sorted: bool = false,
        rev_sorted: bool = false,
        _reserved: u11 = 0,
    };
};

/// Free grouped-run span entry (`free_group_spans` section): the engine
/// keeps one free stack per span length, so the length must round-trip.
pub const FreeGroupSpan = extern struct {
    first_group: u32,
    span_count: u16,
    _reserved: u16 = 0,
};

// ── Size math (shared by writer and loader) ─────────────────────────────

pub fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) / alignment * alignment;
}

fn pagesFor(entry_count: u64, entries_per_page: u64) u64 {
    return (entry_count + entries_per_page - 1) / entries_per_page;
}

/// Page counts derive from the allocation frontiers in the header: storage
/// is written page-for-page up to the page containing the last allocated
/// entry.
pub fn blockPages(block_count: u32) u64 {
    return pagesFor(block_count, constants.EDGE_BLOCKS_PER_PAGE);
}

pub fn groupPages(group_count: u32) u64 {
    return pagesFor(group_count, constants.EDGE_GROUPS_PER_PAGE);
}

pub fn tinyFwdPages(tiny_count: u32) u64 {
    return pagesFor(tiny_count, node_tiny.TINY_FWD_SLOTS_PER_PAGE);
}

pub fn tinyRevPages(tiny_count: u32) u64 {
    return pagesFor(tiny_count, node_tiny.TINY_REV_SLOTS_PER_PAGE);
}

/// Expected payload byte length of a fixed-shape section given the header,
/// or null for the variable-length free-list sections (validated against
/// `entry_count` instead).
pub fn expectedSectionBytes(header: FileHeader, id: SectionId) ?u64 {
    return switch (id) {
        .node_records => header.node_count * @sizeOf(NodeRecord),
        .blocks_fwd => blockPages(header.block_fwd_count) * constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockFwd),
        .blocks_rev => blockPages(header.block_rev_count) * constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockRev),
        .live_fwd => blockPages(header.block_fwd_count) * constants.EDGE_BLOCKS_PER_PAGE,
        .live_rev => blockPages(header.block_rev_count) * constants.EDGE_BLOCKS_PER_PAGE,
        .edge_ids_fwd => if (header.flags.multigraph)
            blockPages(header.block_fwd_count) * constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockFwdIds)
        else
            0,
        .prop_rows_fwd => if (header.flags.edge_properties)
            blockPages(header.block_fwd_count) * constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockFwdProps)
        else
            0,
        .groups => groupPages(header.group_count) * constants.EDGE_GROUPS_PER_PAGE * @sizeOf(types.EdgeBlockGroup),
        .tiny_fwd => tinyFwdPages(header.tiny_fwd_count) * node_tiny.TINY_FWD_SLOTS_PER_PAGE * @sizeOf(node_tiny.TinyFwdSlot),
        .tiny_rev => tinyRevPages(header.tiny_rev_count) * node_tiny.TINY_REV_SLOTS_PER_PAGE * @sizeOf(node_tiny.TinyRevSlot),
        .free_blocks_fwd, .free_blocks_rev, .free_tiny_fwd, .free_tiny_rev, .free_prop_rows => null,
        .free_group_spans => null,
    };
}

pub const SectionTableError = error{
    CorruptSectionTable,
};

/// Structural validation of a section table against its header: ids in
/// declaration order, fixed-shape sizes as derived from the counters,
/// offsets aligned, monotonic, non-overlapping, and starting at
/// PAYLOAD_BASE_OFFSET or later. Per-section checksum verification needs the
/// payload bytes and is left to the loader.
pub fn validateSectionTable(header: FileHeader, table: []const SectionDescriptor) SectionTableError!void {
    if (table.len != MAX_SECTIONS) return error.CorruptSectionTable;

    var next_free_offset: u64 = PAYLOAD_BASE_OFFSET;
    for (table, 0..) |descriptor, expected_id| {
        if (descriptor.id != expected_id) return error.CorruptSectionTable;
        const id: SectionId = @enumFromInt(descriptor.id);

        if (expectedSectionBytes(header, id)) |expected_bytes| {
            if (descriptor.byte_len != expected_bytes) return error.CorruptSectionTable;
        } else {
            const entry_bytes: u64 = if (id == .free_group_spans) @sizeOf(FreeGroupSpan) else @sizeOf(u32);
            if (descriptor.byte_len != descriptor.entry_count * entry_bytes) return error.CorruptSectionTable;
        }

        if (descriptor.byte_len == 0) continue;
        if (descriptor.file_offset % SECTION_ALIGN != 0) return error.CorruptSectionTable;
        if (descriptor.file_offset < next_free_offset) return error.CorruptSectionTable;
        next_free_offset = descriptor.file_offset + descriptor.byte_len;
    }
}

// ── Checksums ────────────────────────────────────────────────────────────

const CHECKSUM_SEED: u64 = MAGIC;

/// Section payload checksum (XxHash64).
pub fn sectionChecksum(payload: []const u8) u64 {
    return std.hash.XxHash64.hash(CHECKSUM_SEED, payload);
}

/// Header checksum: the full HEADER_BYTES block with the `header_checksum`
/// field treated as zero.
pub fn headerChecksum(raw_header_block: []const u8) u64 {
    std.debug.assert(raw_header_block.len == HEADER_BYTES);
    const checksum_offset = @offsetOf(FileHeader, "header_checksum");
    var hasher = std.hash.XxHash64.init(CHECKSUM_SEED);
    hasher.update(raw_header_block[0..checksum_offset]);
    hasher.update(&[_]u8{0} ** @sizeOf(u64));
    hasher.update(raw_header_block[checksum_offset + @sizeOf(u64) ..]);
    return hasher.final();
}

// ── Format invariants ────────────────────────────────────────────────────

comptime {
    // The format is little-endian by definition; a big-endian build would
    // need byte swapping in the (not yet written) reader/writer.
    std.debug.assert(builtin.cpu.arch.endian() == .little);

    std.debug.assert(@sizeOf(NodeRecord) == 48);
    std.debug.assert(@sizeOf(SectionDescriptor) == 32);
    std.debug.assert(@sizeOf(FormatParams) == 12);
    std.debug.assert(@sizeOf(FreeGroupSpan) == 8);
    std.debug.assert(@sizeOf(FileHeader) <= HEADER_BYTES);
    std.debug.assert(SECTION_TABLE_OFFSET % SECTION_ALIGN == 0);
    std.debug.assert(PAYLOAD_BASE_OFFSET % SECTION_ALIGN == 0);

    // Page payloads must keep their in-memory shapes: zero-copy depends on it.
    std.debug.assert(@sizeOf(types.EdgeBlockFwd) == 8 * @as(usize, constants.EDGES_PER_BLOCK));
    std.debug.assert(@sizeOf(types.EdgeBlockRev) == 4 * @as(usize, constants.EDGES_PER_BLOCK));
    std.debug.assert(@sizeOf(types.EdgeBlockGroup) == 8);

    // Intentional anchors: writer/loader will need these modules,
    // and referencing them here documents the dependency.
    _ = page_ops;
    _ = node_hot_layout;
}
