//! Frozen read-only graph over an mmap (SKELETON).
//!
//! Opens a snapshot file with `posix.mmap(PROT_READ, MAP_PRIVATE)` and
//! serves queries directly from the mapped sections: NodeRecords for
//! degrees/flags/adjacency headers, raw block/tiny/group sections for the
//! edges themselves. Nothing is copied; the kernel pages the file in lazily
//! as queries touch it, and N processes mapping the same snapshot share one
//! physical copy through the page cache.
//!
//! This type is deliberately SEPARATE from `Graph`: a frozen snapshot is
//! immutable, so none of the live machinery applies — no RCU, no reader
//! tokens, no seqlocks, no epochs, no repair. Concurrent use from any
//! number of threads is trivially safe. That absence of machinery is the
//! payoff of the whole design: the format IS the read-side data structure.
//!
//! Mutation story: there is none, by contract. "Load then keep writing" is
//! the copy loader (`loader.load`); this type is the instant zero-copy open
//! for query/analytics/embedded workloads.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");
const node_tiny = @import("../node/tiny.zig");
const format = @import("format.zig");
const io_mod = @import("io.zig");

pub const OpenError = anyerror; // TODO: narrow.

pub const OpenOptions = struct {
    /// Verify every per-section checksum at open. This reads the whole file
    /// once (sequential, readahead-friendly) — it trades the lazy-load
    /// benefit for integrity-on-open. With `false`, only the header and
    /// section table are validated and corruption in payload bytes would
    /// surface as wrong query results instead of an open error.
    verify_checksums: bool = true,
};

pub const FrozenGraph = struct {
    /// The whole file, mapped PROT_READ. Page-aligned by mmap contract.
    bytes: []align(std.heap.page_size_min) const u8,
    header: format.FileHeader,
    table: [format.MAX_SECTIONS]format.SectionDescriptor,

    /// Opens and maps `<sub_path>`. Steps: open → stat (length) → mmap
    /// PROT_READ + MAP_PRIVATE → close the fd (the mapping keeps the inode
    /// alive on its own — same reason a reader survives a publisher's
    /// rename) → validation ladder from io.zig (header, table, length,
    /// checksums per OpenOptions).
    pub fn open(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, options: OpenOptions) OpenError!FrozenGraph {
        _ = io;
        _ = dir;
        _ = sub_path;
        _ = options;
        // TODO: posix.mmap(null, len, PROT.READ, .{ .TYPE =
        // .PRIVATE }, file.handle, 0); then io_mod.parseHeader /
        // parseSectionTable / checkSectionsAgainstFileLen — the ladder is
        // the loader's; only materialization differs (map vs copy).
        @panic("TODO: FrozenGraph.open");
    }

    pub fn close(self: *FrozenGraph) void {
        _ = self;
        // TODO: posix.munmap(self.bytes); poison self.
        @panic("TODO: FrozenGraph.close");
    }

    // ── Section access ───────────────────────────────────────────────

    /// Raw payload bytes of one section (zero-length for absent optional
    /// sections). The base pointer is SECTION_ALIGN-aligned by format
    /// contract, so casting to the section's record type is sound.
    pub fn sectionBytes(self: *const FrozenGraph, id: format.SectionId) []const u8 {
        _ = self;
        _ = id;
        @panic("TODO: sectionBytes");
    }

    /// All NodeRecords, casted in place from the node_records section.
    pub fn nodeRecords(self: *const FrozenGraph) []const format.NodeRecord {
        _ = self;
        // TODO: std.mem.bytesAsSlice over sectionBytes — alignment
        // holds because SECTION_ALIGN covers the record alignment (the
        // format's comptime asserts pin this).
        @panic("TODO: nodeRecords");
    }

    // ── Counters / point lookups ─────────────────────────────────────

    pub fn nodeCount(self: *const FrozenGraph) u64 {
        _ = self;
        @panic("TODO: nodeCount");
    }

    pub fn edgeCount(self: *const FrozenGraph) u64 {
        _ = self;
        @panic("TODO: edgeCount");
    }

    pub fn nodeRecord(self: *const FrozenGraph, node: types.NodeId) ?*const format.NodeRecord {
        _ = self;
        _ = node;
        // TODO: null when out of range or record.flags.removed.
        @panic("TODO: nodeRecord");
    }

    pub fn outDegree(self: *const FrozenGraph, node: types.NodeId) types.GraphError!usize {
        _ = self;
        _ = node;
        @panic("TODO: outDegree");
    }

    pub fn inDegree(self: *const FrozenGraph, node: types.NodeId) types.GraphError!usize {
        _ = self;
        _ = node;
        @panic("TODO: inDegree");
    }

    /// Block lookup straight off the mapped section: index → page → slot,
    /// pure arithmetic (block_idx / EDGE_BLOCKS_PER_PAGE picks the page,
    /// % picks the slot — pages are contiguous in the section, so this
    /// flattens to a single multiply).
    pub fn blockFwd(self: *const FrozenGraph, block_idx: u32) *const types.EdgeBlockFwd {
        _ = self;
        _ = block_idx;
        @panic("TODO: blockFwd");
    }

    pub fn blockRev(self: *const FrozenGraph, block_idx: u32) *const types.EdgeBlockRev {
        _ = self;
        _ = block_idx;
        @panic("TODO: blockRev");
    }

    pub fn blockLiveFwd(self: *const FrozenGraph, block_idx: u32) u8 {
        _ = self;
        _ = block_idx;
        @panic("TODO: blockLiveFwd");
    }

    pub fn blockLiveRev(self: *const FrozenGraph, block_idx: u32) u8 {
        _ = self;
        _ = block_idx;
        @panic("TODO: blockLiveRev");
    }

    pub fn groupAt(self: *const FrozenGraph, group_idx: u32) *const types.EdgeBlockGroup {
        _ = self;
        _ = group_idx;
        @panic("TODO: groupAt");
    }

    pub fn tinyFwdAt(self: *const FrozenGraph, slot_idx: u32) *const node_tiny.TinyFwdSlot {
        _ = self;
        _ = slot_idx;
        @panic("TODO: tinyFwdAt");
    }

    pub fn tinyRevAt(self: *const FrozenGraph, slot_idx: u32) *const node_tiny.TinyRevSlot {
        _ = self;
        _ = slot_idx;
        @panic("TODO: tinyRevAt");
    }

    // ── Traversal ────────────────────────────────────────────────────

    /// Forward-neighbor iterator over a frozen node. Same three side shapes
    /// as the live engine, minus all concurrency:
    ///   - tiny side: first_block carries side_ops.TINY_SLOT_TAG; entries
    ///     come from the tiny slot, count from the published tiny count
    ///     convention (see NodePublished.tinyCount / the record's degree),
    ///   - contiguous run: group_count == 0 → block_count blocks starting
    ///     at first_block, each read up to its live count,
    ///   - grouped runs: group_count EdgeBlockGroup descriptors starting at
    ///     first_group, each one a (first_block, span) run.
    pub fn outNeighbors(self: *const FrozenGraph, node: types.NodeId) types.GraphError!NeighborIterator {
        _ = self;
        _ = node;
        @panic("TODO: outNeighbors");
    }

    pub fn inNeighbors(self: *const FrozenGraph, node: types.NodeId) types.GraphError!NeighborIterator {
        _ = self;
        _ = node;
        @panic("TODO: inNeighbors");
    }

    pub const NeighborIterator = struct {
        frozen: *const FrozenGraph,
        // TODO: cursor state — direction, the SideAdj snapshot
        // (copied from the record: 16 bytes, cheap), current block/slot/
        // group indices, tiny mode + index. No tokens, no liveness checks:
        // the data cannot move.

        pub fn next(self: *NeighborIterator) ?types.NodeId {
            _ = self;
            @panic("TODO: NeighborIterator.next");
        }
    };

    /// Optional finale: CSR export straight from the mapping (offsets from
    /// the record degrees, targets by walking each side) so a frozen
    /// snapshot can feed analytics without ever building a live graph.
    pub fn materializeForwardCsr(self: *const FrozenGraph, allocator: std.mem.Allocator) anyerror!void {
        _ = self;
        _ = allocator;
        // TODO (optional): mirror the shape of
        // query/snapshot/csr.zig's CsrView (out_offsets/out_targets[/out_rows]).
        @panic("TODO: materializeForwardCsr");
    }
};

comptime {
    _ = constants;
    _ = io_mod;
}
