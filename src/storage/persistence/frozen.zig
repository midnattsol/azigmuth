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
const adjacency = @import("../../adjacency/mod.zig");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");
const node_tiny = @import("../node/tiny.zig");
const format = @import("format.zig");
const io_mod = @import("io.zig");
const node_published = @import("../node/published.zig");

pub const OpenError = anyerror; // TODO: Real errors once is done.

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
        const descriptor = self.table[@intFromEnum(id)];
        const offset = descriptor.file_offset;
        const length = descriptor.byte_len;

        if (length == 0) return &[_]u8{};
        return self.bytes[offset .. offset + length];
    }

    /// All NodeRecords, casted in place from the node_records section.
    pub fn nodeRecords(self: *const FrozenGraph) []const format.NodeRecord {
        const bytes = self.sectionBytes(.node_records);
        const records: []const format.NodeRecord = std.mem.bytesAsSlice(format.NodeRecord, bytes);
        return records;
    }

    // ── Counters / point lookups ─────────────────────────────────────

    pub fn nodeCount(self: *const FrozenGraph) u64 {
        return self.header.node_count;
    }

    pub fn edgeCount(self: *const FrozenGraph) u64 {
        return self.header.edge_count;
    }

    pub fn nodeRecord(self: *const FrozenGraph, node: types.NodeId) ?*const format.NodeRecord {
        if (node.index >= self.nodeCount()) return null;
        const node_record = &self.nodeRecords()[node.index];

        if (node_record.flags.removed) return null;
        return node_record;
    }

    pub fn outDegree(self: *const FrozenGraph, node: types.NodeId) types.GraphError!usize {
        const node_record = self.nodeRecord(node);
        if (node_record == null) return error.InvalidNode;
        return node_record.degree_fwd;
    }

    pub fn inDegree(self: *const FrozenGraph, node: types.NodeId) types.GraphError!usize {
        const node_record = self.nodeRecord(node);
        if (node_record == null) return error.InvalidNode;
        return node_record.degree_rev;
    }

    /// Block lookup straight off the mapped section: index → page → slot,
    /// pure arithmetic (block_idx / EDGE_BLOCKS_PER_PAGE picks the page,
    /// % picks the slot — pages are contiguous in the section, so this
    /// flattens to a single multiply).
    pub fn edgeBlockAt(self: *const FrozenGraph, block_idx: u32, comptime side: adjacency.AdjSide) *const switch (side) {
        .fwd => types.EdgeBlockFwd,
        .rev => types.EdgeBlockRev,
    } {
        const bytes = self.sectionBytes(switch (side) {
            .fwd => .blocks_fwd,
            .rev => .blocks_rev,
        });
        const ptr: *const switch (side) {
            .fwd => types.EdgeBlockFwd,
            .rev => types.EdgeBlockRev,
        } = @ptrCast(@alignCast(bytes.ptr));
        return &ptr[block_idx];
    }

    pub fn liveCountInBlock(self: *const FrozenGraph, block_idx: u32, side: adjacency.AdjSide) u8 {
        return self.sectionBytes(switch (side) {
            .fwd => .live_fwd,
            .rev => .live_rev,
        })[block_idx];
    }

    pub fn edgeBlockGroupAt(self: *const FrozenGraph, group_idx: u32) *const types.EdgeBlockGroup {
        const bytes = self.sectionBytes(.groups);
        const ptr: *const types.EdgeBlockGroup = @ptrCast(@alignCast(bytes.ptr));
        return &ptr[group_idx];
    }

    pub fn tinyBlockAt(self: *const FrozenGraph, block_idx: u32, comptime side: adjacency.AdjSide) *const switch (side) {
        .fwd => node_tiny.TinyFwdBlock,
        .rev => node_tiny.TinyRevBlock,
    } {
        const bytes = self.sectionBytes(switch (side) {
            .fwd => .tiny_fwd,
            .rev => .tiny_rev,
        });
        const ptr: *const switch (side) {
            .fwd => node_tiny.TinyFwdBlock,
            .rev => node_tiny.TinyRevBlock,
        } = @ptrCast(@alignCast(bytes.ptr));
        return &ptr[block_idx];
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
        const node_record = self.nodeRecord(node);
        if (node_record == null) return error.InvalidNode;

        const side_adj: types.SideAdj = node_record.fwd;
        if (node_published.NodePublished.isTiny(&side_adj)) {
            return NeighborIterator{
                .frozen = self,
                .direction = .fwd,
                .tiny_idx = 0,
                .tiny_mode = true,
                .tiny_block_idx = side_adj.first_block,
                .tiny_count = node_published.NodePublished.tinyCount(&side_adj),
                .current_block_idx = 0,
                .slot_idx = 0,
                .blocks_remaining = 0,
                .group_idx = 0,
                .groups_remaining = 0,
                .live_in_block = 0,
            };
        } else if (side_adj.group_count == 0) {
            return NeighborIterator{
                .frozen = self,
                .direction = .fwd,
                .tiny_idx = 0,
                .tiny_mode = false,
                .tiny_block_idx = 0,
                .tiny_count = 0,
                .current_block_idx = side_adj.first_block,
                .slot_idx = 0,
                .blocks_remaining = side_adj.block_count,
                .group_idx = 0,
                .groups_remaining = 0,
                .live_in_block = self.liveCountInBlock(side_adj.first_block, .fwd),
            };
        } else {
            const group = self.edgeBlockGroupAt(side_adj.first_group);
            return NeighborIterator{
                .frozen = self,
                .direction = .fwd,
                .tiny_idx = 0,
                .tiny_mode = false,
                .tiny_block_idx = 0,
                .tiny_count = 0,
                .current_block_idx = group.start,
                .slot_idx = 0,
                .blocks_remaining = group.count,
                .group_idx = side_adj.first_group,
                .groups_remaining = side_adj.group_count,
                .live_in_block = self.liveCountInBlock(group.start, .fwd),
            };
        }
    }

    pub fn inNeighbors(self: *const FrozenGraph, node: types.NodeId) types.GraphError!NeighborIterator {
        const node_record = self.nodeRecord(node);
        if (node_record == null) return error.InvalidNode;

        const side_adj: types.SideAdj = node_record.rev;
        if (node_published.NodePublished.isTiny(&side_adj)) {
            return NeighborIterator{
                .frozen = self,
                .direction = .rev,
                .tiny_idx = 0,
                .tiny_mode = true,
                .tiny_block_idx = side_adj.first_block,
                .tiny_count = node_published.NodePublished.tinyCount(&side_adj),
                .current_block_idx = 0,
                .slot_idx = 0,
                .blocks_remaining = 0,
                .group_idx = 0,
                .groups_remaining = 0,
                .live_in_block = 0,
            };
        } else if (side_adj.group_count == 0) {
            return NeighborIterator{
                .frozen = self,
                .direction = .rev,
                .tiny_idx = 0,
                .tiny_mode = false,
                .tiny_block_idx = 0,
                .tiny_count = 0,
                .current_block_idx = side_adj.first_block,
                .slot_idx = 0,
                .blocks_remaining = side_adj.block_count,
                .group_idx = 0,
                .groups_remaining = 0,
                .live_in_block = self.liveCountInBlock(side_adj.first_block, .rev),
            };
        } else {
            const group = self.edgeBlockGroupAt(side_adj.first_group);
            return NeighborIterator{
                .frozen = self,
                .direction = .rev,
                .tiny_idx = 0,
                .tiny_mode = false,
                .tiny_block_idx = 0,
                .tiny_count = 0,
                .current_block_idx = group.start,
                .slot_idx = 0,
                .blocks_remaining = group.count,
                .group_idx = side_adj.first_group,
                .groups_remaining = side_adj.group_count,
                .live_in_block = self.liveCountInBlock(group.start, .rev),
            };
        }
    }

    pub const NeighborIterator = struct {
        frozen: *const FrozenGraph,
        direction: enum { fwd, rev },

        // Tiny mode
        tiny_mode: bool,
        tiny_block_idx: u32,
        tiny_count: u16,
        tiny_idx: u16,

        // Current block
        current_block_idx: u32,
        blocks_remaining: u32,
        slot_idx: u8,
        live_in_block: u8,

        // Current group
        group_idx: u32,
        groups_remaining: u16,

        pub fn next(self: *NeighborIterator) ?types.NodeId {
            var neighbor: ?types.NodeId = undefined;
            if (self.tiny_mode) {
                if (self.tiny_count <= self.tiny_idx) return null;
                neighbor = switch (self.direction) {
                    .fwd => blk: {
                        const block = self.frozen.tinyBlockAt(self.tiny_block_idx, .fwd);
                        const destination = block.entries[self.tiny_idx].destination;
                        break :blk types.NodeId{ .index = destination };
                    },
                    .rev => blk: {
                        const block = self.frozen.tinyBlockAt(self.tiny_block_idx, .rev);
                        const source = block.sources[self.tiny_idx];
                        break :blk types.NodeId{ .index = source };
                    },
                };
                self.tiny_idx += 1;
                return neighbor;
            }
            while (true) {
                if (self.slot_idx < self.live_in_block) {
                    neighbor = switch (self.direction) {
                        .fwd => blk: {
                            const block = self.frozen.edgeBlockAt(self.current_block_idx, .fwd);
                            const destination = block.destinations[self.slot_idx];
                            break :blk types.NodeId{ .index = destination };
                        },
                        .rev => blk: {
                            const block = self.frozen.edgeBlockAt(self.current_block_idx, .rev);
                            const source = block.sources[self.slot_idx];
                            break :blk types.NodeId{ .index = source };
                        },
                    };
                    self.slot_idx += 1;
                    return neighbor;
                } else if (self.blocks_remaining > 1) {
                    self.current_block_idx += 1;
                    self.blocks_remaining -= 1;
                    self.slot_idx = 0;
                    self.live_in_block = self.frozen.liveCountInBlock(self.current_block_idx, self.direction);
                    continue;
                } else if (self.groups_remaining > 1) {
                    self.group_idx += 1;
                    self.groups_remaining -= 1;
                    const group = self.frozen.edgeBlockGroupAt(self.group_idx);
                    self.blocks_remaining = group.count;
                    self.current_block_idx = group.start;
                    self.live_in_block = self.frozen.liveCountInBlock(self.current_block_idx, self.direction);
                    self.slot_idx = 0;
                    continue;
                } else return null;
            }
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
