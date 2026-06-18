//! Snapshot writer (SKELETON: every body is a TODO).
//!
//! Serializes a quiesced `GraphCore` into the on-disk format defined by
//! `format.zig`. The format module owns all layout decisions (sections,
//! sizes, checksums); this module owns the I/O choreography:
//!
//!   1. quiesce + `rcu.reclaimRetired` (retired state is not representable),
//!   2. plan the section table (entry counts, byte lengths, aligned offsets),
//!   3. hash pass: stream every section payload through an `io.HashingSink`
//!      to fill the per-section checksums (payloads are composed twice — RAM
//!      streaming is cheap, and it keeps the file write purely sequential),
//!   4. write pass: header block + section table + payloads (with alignment
//!      padding) into `<sub_path>.tmp` through a buffered `io.FileSink`,
//!   5. flush + `File.sync` (fsync: wait for the dirty pages to drain),
//!   6. `Dir.rename` tmp → final (atomic publish; same-directory is required),
//!   7. on any failure: best-effort delete of the tmp.
//!
//! The two streaming passes share `emitSection`, so the bytes that were
//! hashed are — by construction — the bytes that get written.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const page_ops = @import("../page_ops.zig");
const node_access = @import("../../core/node_access.zig");
const node_tiny = @import("../node/tiny.zig");
const rcu = @import("../../concurrency/rcu.zig");
const format = @import("format.zig");
const io_mod = @import("io.zig");

// TODO: narrow this to a real error set once the helpers exist
// (file open/write/sync/rename errors + OutOfMemory for the plan buffers).
pub const SaveError = anyerror;

/// Serializes the graph to `<sub_path>` via write-tmp + fsync + rename.
///
/// Contract (normative, mirrors the save contract in format.zig): the graph
/// must be quiesced — no concurrent readers, writers, or repairers (same
/// precondition as `deinitChecked`). This function segments
/// `rcu.reclaimRetired` itself as step 0 so every retired
/// block/segment/tiny-slot/prop-row has drained into the free structures.
pub fn save(core: *graph_core.GraphCore, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) SaveError!void {
    _ = core;
    _ = io;
    _ = dir;
    _ = sub_path;
    // TODO orchestration:
    //   0. rcu.reclaimRetired(core);
    //   1. var header = format.FileHeader.init(core);
    //   2. var plan = try planSections(core, header);
    //   3. hash pass: for each section, segment emitSection into an
    //      io_mod.HashingSink and store the digest in plan.table[i].checksum.
    //   4. serialize header block (serializeHeaderBlock) + section table
    //      (serializeSectionTable).
    //   5. tmp name: sub_path ++ ".tmp" (same directory as the target —
    //      rename is only atomic within one filesystem).
    //   6. createFile(tmp) → io_mod.FileSink → write header block, table,
    //      then for each section: zero-padding up to file_offset, then
    //      emitSection.
    //   7. sink.flush() → file.sync(io) → file.close(io).
    //   8. dir.rename(io, tmp, sub_path).
    //   9. errdefer along the way: dir.deleteFile(io, tmp) best effort.
    @panic("TODO: save");
}

// ── Section planning ─────────────────────────────────────────────────────

pub const SectionPlan = struct {
    table: [format.MAX_SECTIONS]format.SectionDescriptor,
    /// Total file length implied by the last section (useful for tests and
    /// for preallocating, not required by the format).
    file_len: u64,
};

/// Computes entry counts, byte lengths and 64-byte-aligned offsets for all
/// sections, in `SectionId` order. Checksums are left at 0 (the hash pass
/// fills them). Needs to walk the free stacks to count their entries —
/// see `countFreeStack`.
pub fn planSections(core: *const graph_core.GraphCore, header: format.FileHeader) SaveError!SectionPlan {
    var table: [format.MAX_SECTIONS]format.SectionDescriptor = undefined;

    // Compute entry counts and byte lengths for all 16 sections in SectionId order.
    var id_int: u16 = 0;
    while (id_int < format.MAX_SECTIONS) : (id_int += 1) {
        const id: format.SectionId = @enumFromInt(id_int);

        const entry_count: u32 = switch (id) {
            .node_records => @intCast(header.node_count),
            .blocks_fwd => @intCast(format.blockPages(header.block_fwd_count)),
            .blocks_rev => @intCast(format.blockPages(header.block_rev_count)),
            .alive_fwd => @intCast(format.blockPages(header.block_fwd_count)),
            .alive_rev => @intCast(format.blockPages(header.block_rev_count)),
            .edge_ids_fwd => if (header.flags.multigraph) @intCast(format.blockPages(header.block_fwd_count)) else 0,
            .prop_rows_fwd => if (header.flags.edge_properties) @intCast(format.blockPages(header.block_fwd_count)) else 0,
            .segments => @intCast(format.segmentPages(header.segment_count)),
            .tiny_fwd => @intCast(format.tinyFwdPages(header.tiny_fwd_slot_count)),
            .tiny_rev => @intCast(format.tinyRevPages(header.tiny_rev_slot_count)),
            .free_blocks_fwd => countFreeStack(core, .blocks_fwd),
            .free_blocks_rev => countFreeStack(core, .blocks_rev),
            .free_segment_slots => countFreeSegmentSlots(core),
            .free_tiny_fwd => countFreeStack(core, .tiny_fwd),
            .free_tiny_rev => countFreeStack(core, .tiny_rev),
            .free_prop_rows => countFreeStack(core, .prop_rows),
        };

        const byte_len: u64 = if (format.expectedSectionBytes(header, id)) |expected| expected else blk: {
            const element_size: u64 = if (id == .free_segment_slots) @sizeOf(format.FreeSegmentSlots) else @sizeOf(u32);
            break :blk @as(u64, entry_count) * element_size;
        };

        table[id_int] = .{
            .id = id_int,
            ._reserved = 0,
            .entry_count = entry_count,
            .file_offset = 0,
            .byte_len = byte_len,
            .checksum = 0,
        };
    }

    // Compute aligned offsets and total file length.
    var offset: u64 = format.PAYLOAD_BASE_OFFSET;
    var file_len: u64 = format.PAYLOAD_BASE_OFFSET;
    for (&table) |*descriptor| {
        if (descriptor.byte_len == 0) continue;
        offset = format.alignForward(offset, format.SECTION_ALIGN);
        descriptor.file_offset = offset;
        offset += descriptor.byte_len;
        file_len = descriptor.file_offset + descriptor.byte_len;
    }

    return .{ .table = table, .file_len = file_len };
}

// ── Payload streaming (shared by the hash pass and the write pass) ───────

/// Streams one section's payload bytes, in file order, into `sink`.
/// Must emit exactly the planned byte_len for that section.
pub fn emitSection(core: *const graph_core.GraphCore, id: format.SectionId, sink: io_mod.PayloadSink) anyerror!void {
    return switch (id) {
        .node_records => emitNodeRecords(core, sink),
        .blocks_fwd => emitBlockPages(core, sink, .fwd),
        .blocks_rev => emitBlockPages(core, sink, .rev),
        .alive_fwd => emitLivePages(core, sink, .fwd),
        .alive_rev => emitLivePages(core, sink, .rev),
        .edge_ids_fwd => emitEdgeIdPages(core, sink),
        .prop_rows_fwd => emitPropRowPages(core, sink),
        .segments => emitSegmentPages(core, sink),
        .tiny_fwd => emitTinyPages(core, sink, .fwd),
        .tiny_rev => emitTinyPages(core, sink, .rev),
        .free_blocks_fwd => emitFreeBlockList(core, sink, core.allocator, .fwd),
        .free_blocks_rev => emitFreeBlockList(core, sink, core.allocator, .rev),
        .free_segment_slots => emitFreeSegmentSlots(core, sink, core.allocator),
        .free_tiny_fwd => emitFreeTinyList(core, sink, core.allocator, .fwd),
        .free_tiny_rev => emitFreeTinyList(core, sink, core.allocator, .rev),
        .free_prop_rows => emitFreePropRows(core, sink, core.allocator),
    };
}

// ── Per-section emitters ─────────────────────────────────────────────────

/// Composes one `NodeRecord` per node (0..node_count) and emits them in
/// batches. The record is the published view normalized out of the RCU
/// double-buffers — see makeNodeRecord.
fn emitNodeRecords(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    const node_count = core.publishedNodeCount();
    var batch: [64]format.NodeRecord = undefined;
    var batch_idx: usize = 0;
    for (0..node_count) |node_idx| {
        batch[batch_idx] = makeNodeRecord(core, @intCast(node_idx));
        batch_idx += 1;
        if (batch_idx == 64) {
            try sink.emit(std.mem.sliceAsBytes(batch[0..batch_idx]));
            batch_idx = 0;
        }
    }
    if (batch_idx > 0) try sink.emit(std.mem.sliceAsBytes(batch[0..batch_idx]));
}

/// Normalizes one node's published state into its canonical NodeRecord:
/// active SideAdj per direction (node_access / NodeAdjacencyBuffers), degrees,
/// next_local_edge_id (NodeMutationControl), and the flag bits (removed,
/// needs_repair_*, sorted bits). Pure — unit-test it on its own.
pub fn makeNodeRecord(core: *const graph_core.GraphCore, node_idx: u32) format.NodeRecord {
    const node_id = types.NodeId{ .index = node_idx };
    const state = page_ops.nodePublicationAtConst(core, node_id).loadPublicationState();
    const buffers = page_ops.nodeAdjacencyBuffersAtConst(core, node_id);

    const fwd = buffers.fwd[state.idx_fwd];
    const rev = buffers.rev[state.idx_rev];

    const fwd_degree: u32 = if (state.degree_fwd_overflow) buffers.degrees_fwd[state.idx_fwd] else state.degree_fwd;
    const rev_degree: u32 = if (state.degree_rev_overflow) buffers.degrees_rev[state.idx_rev] else state.degree_rev;

    const mutation_control = page_ops.nodeMutationControlAtConst(core, node_id);
    const next_local_edge_id = mutation_control.loadNextLocalEdgeId();

    const sorted_fwd = buffers.sorted_fwd[state.idx_fwd] != 0;
    const sorted_rev = buffers.sorted_rev[state.idx_rev] != 0;

    return format.NodeRecord{
        .fwd = fwd,
        .rev = rev,
        .degree_fwd = fwd_degree,
        .degree_rev = rev_degree,
        .flags = .{
            .removed = state.removed,
            .sorted_fwd = sorted_fwd,
            .sorted_rev = sorted_rev,
            .needs_repair_fwd = state.needs_repair_fwd,
            .needs_repair_rev = state.needs_repair_rev,
        },
        .next_local_edge_id = next_local_edge_id,
    };
}

/// Emits the raw `EdgeBlockFwd`/`EdgeBlockRev` pages, page-for-page, up to
/// the page containing block index `loadBlock*Count() - 1`
/// (format.blockPages). Whole pages are emitted, including slots past the
/// allocation frontier inside the last page.
fn emitBlockPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    const block_count = switch (side) {
        .fwd => core.loadBlockFwdCount(),
        .rev => core.loadBlockRevCount(),
    };
    const page_count = format.blockPages(block_count);
    const block_byte_len = switch (side) {
        .fwd => @sizeOf(types.EdgeBlockFwd),
        .rev => @sizeOf(types.EdgeBlockRev),
    };
    const page_byte_len = constants.EDGE_BLOCKS_PER_PAGE * block_byte_len;
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = page_ops.edgeBlockPageRaw(core, page_idx, side);
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

/// Emits the u8 alive-count sidecar pages for `side`, same page walk as
/// emitBlockPages (page_ops.blockAlivePageRaw).
fn emitLivePages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    const block_count = switch (side) {
        .fwd => core.loadBlockFwdCount(),
        .rev => core.loadBlockRevCount(),
    };
    const page_count = format.blockPages(block_count);
    const page_byte_len = constants.EDGE_BLOCKS_PER_PAGE;
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = page_ops.blockAlivePageRaw(core, page_idx, side);
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

/// Emits `EdgeBlockFwdIds` pages (multigraph mode; otherwise emits nothing
/// — the planned byte_len is 0).
fn emitEdgeIdPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    const block_count = core.loadBlockFwdCount();
    if (block_count == 0) return;
    const page_count = format.blockPages(block_count);
    const page_byte_len = constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockFwdIds);
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = page_ops.edgeBlockFwdIdsPageRaw(core, page_idx);
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

/// Emits `EdgeBlockFwdProps` pages (edge_properties mode; otherwise nothing).
fn emitPropRowPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    const block_count = core.loadBlockFwdCount();
    if (block_count == 0) return;
    const page_count = format.blockPages(block_count);
    const page_byte_len = constants.EDGE_BLOCKS_PER_PAGE * @sizeOf(types.EdgeBlockFwdProps);
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = page_ops.edgeBlockFwdPropsPageRaw(core, page_idx);
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

/// Emits `EdgeBlockSegment` pages up to segmentPages(loadSegmentCount()).
fn emitSegmentPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    const segment_count = core.loadSegmentCount();
    const page_count = format.segmentPages(segment_count);
    const page_byte_len = constants.EDGE_SEGMENTS_PER_PAGE * @sizeOf(types.EdgeBlockSegment);
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = core.edge_block_segment_pages.load(page_idx);
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

/// Emits Tiny{Fwd,Rev}Slot pages up to tiny*Pages(loadTiny*Count()).
fn emitTinyPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    const tiny_count = switch (side) {
        .fwd => core.loadTinyFwdCount(),
        .rev => core.loadTinyRevCount(),
    };
    const per_page: u32 = switch (side) {
        .fwd => node_tiny.TINY_FWD_SLOTS_PER_PAGE,
        .rev => node_tiny.TINY_REV_SLOTS_PER_PAGE,
    };
    const block_size: usize = switch (side) {
        .fwd => @sizeOf(node_tiny.TinyFwdSlot),
        .rev => @sizeOf(node_tiny.TinyRevSlot),
    };
    const page_count: u64 = switch (side) {
        .fwd => format.tinyFwdPages(tiny_count),
        .rev => format.tinyRevPages(tiny_count),
    };
    const page_byte_len = per_page * block_size;
    for (0..@as(usize, @intCast(page_count))) |page_idx_usize| {
        const page_idx: u32 = @intCast(page_idx_usize);
        const raw_ptr: usize = switch (side) {
            .fwd => core.tiny_fwd_slot_pages.load(page_idx),
            .rev => core.tiny_rev_slot_pages.load(page_idx),
        };
        try sink.emit(@as([*]const u8, @ptrFromInt(raw_ptr))[0..page_byte_len]);
    }
}

// ── Free-list emitters ───────────────────────────────────────────────────
//
// The free stacks are lock-free tagged stacks: the head lives in GraphCore
// (low 32 bits = first index, END_OF_CHAIN = empty) and the `next` links
// live in the per-entry reclamation pages. Walking them without mutating is safe
// under the quiesced-save contract, BUT the reclamation accessors are currently
// private to page_ops — part of this stage is adding the minimal pub
// helpers there (suggested: `page_ops.freeStackFirst(core, which)` and
// `page_ops.freeStackNext(core, which, index)`), used by both the counting
// pass (planSections) and the emit pass.

pub const FreeStackId = enum {
    blocks_fwd,
    blocks_rev,
    tiny_fwd,
    tiny_rev,
    prop_rows,
};

/// Counts the entries of one free stack (planSections needs it before any
/// payload is emitted).
pub fn countFreeStack(core: *const graph_core.GraphCore, which: FreeStackId) u32 {
    const head_value: u64 = switch (which) {
        .blocks_fwd => core.free_blocks_fwd_head.load(.acquire),
        .blocks_rev => core.free_blocks_rev_head.load(.acquire),
        .tiny_fwd => core.free_tiny_fwd_slot_head.load(.acquire),
        .tiny_rev => core.free_tiny_rev_slot_head.load(.acquire),
        .prop_rows => core.free_prop_rows_head.load(.acquire),
    };
    const per_page: u32 = switch (which) {
        .blocks_fwd, .blocks_rev => constants.EDGE_BLOCKS_PER_PAGE,
        .tiny_fwd => node_tiny.TINY_FWD_SLOTS_PER_PAGE,
        .tiny_rev => node_tiny.TINY_REV_SLOTS_PER_PAGE,
        .prop_rows => constants.PROP_ROWS_PER_PAGE,
    };

    const LinkContext = struct {
        core: *const graph_core.GraphCore,
        which: FreeStackId,
        per_page: u32,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = current / self.per_page;
            const slot_idx = current % self.per_page;
            const raw: usize = switch (self.which) {
                .blocks_fwd => self.core.edge_blocks_fwd_reclamation_pages.load(page_idx),
                .blocks_rev => self.core.edge_blocks_rev_reclamation_pages.load(page_idx),
                .tiny_fwd => self.core.tiny_fwd_slot_reclamation_pages.load(page_idx),
                .tiny_rev => self.core.tiny_rev_slot_reclamation_pages.load(page_idx),
                .prop_rows => self.core.prop_row_reclamation_pages.load(page_idx),
            };
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };
    const CountingVisitor = struct {
        count: u32 = 0,

        pub fn visit(self: *@This(), _: u32) !void {
            self.count += 1;
        }
    };

    const first_index = page_ops.stackHeadIndex(head_value);
    var counting_visitor = CountingVisitor{};
    const link_ctx = LinkContext{ .core = core, .which = which, .per_page = per_page };
    page_ops.walkDetachedIndexStack(first_index, link_ctx, &counting_visitor) catch unreachable;
    return counting_visitor.count;
}

/// Counts the total number of free segment slot entry entries across all slot-count
/// stacks. Mirrors the counting pattern in `countFreeStack` but iterates over
/// the per-slot-count free lists in `free_segment_slots_head`.
fn countFreeSegmentSlots(core: *const graph_core.GraphCore) u32 {
    const LinkContext = struct {
        core: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = page_ops.pageOf(current, constants.EDGE_SEGMENTS_PER_PAGE);
            const slot_idx = page_ops.slotOf(current, constants.EDGE_SEGMENTS_PER_PAGE);
            const raw: usize = self.core.edge_block_segment_reclamation_pages.load(page_idx);
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };
    const CountingVisitor = struct {
        count: u32 = 0,

        pub fn visit(self: *@This(), _: u32) !void {
            self.count += 1;
        }
    };

    var total: u32 = 0;
    var slot_count: u16 = 1;
    while (slot_count <= constants.MAX_SEGMENTS_PER_NODE) : (slot_count += 1) {
        const slot_count_idx: usize = @intCast(slot_count - 1);
        const head: u64 = core.free_segment_slots_head[slot_count_idx].load(.acquire);
        const first_index = page_ops.stackHeadIndex(head);
        if (first_index == page_ops.EMPTY_INDEX) continue;

        var visitor = CountingVisitor{};
        page_ops.walkDetachedIndexStack(first_index, LinkContext{ .core = core }, &visitor) catch unreachable;
        total += visitor.count;
    }
    return total;
}

/// Emits the free block indices of `side` as raw u32s (drain order is
/// irrelevant — the loader just pushes them back).
fn emitFreeBlockList(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide) anyerror!void {
    const head: u64 = switch (side) {
        .fwd => core.free_blocks_fwd_head.load(.acquire),
        .rev => core.free_blocks_rev_head.load(.acquire),
    };
    const first_index = page_ops.stackHeadIndex(head);
    if (first_index == page_ops.EMPTY_INDEX) return;

    const LinkContext = struct {
        core: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = page_ops.pageOf(current, constants.EDGE_BLOCKS_PER_PAGE);
            const slot_idx = page_ops.slotOf(current, constants.EDGE_BLOCKS_PER_PAGE);
            const raw: usize = switch (side) {
                .fwd => self.core.edge_blocks_fwd_reclamation_pages.load(page_idx),
                .rev => self.core.edge_blocks_rev_reclamation_pages.load(page_idx),
            };
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };

    var free_list: std.ArrayList(u32) = .empty;
    defer free_list.deinit(allocator);

    const EmittingVisitor = struct {
        allocator: std.mem.Allocator,
        list: *std.ArrayList(u32),

        pub fn visit(self: *@This(), index: u32) !void {
            try self.list.append(self.allocator, index);
        }
    };

    var emitting_visitor = EmittingVisitor{ .allocator = allocator, .list = &free_list };
    try page_ops.walkDetachedIndexStack(first_index, LinkContext{ .core = core }, &emitting_visitor);
    try sink.emit(std.mem.sliceAsBytes(free_list.items));
}

/// Emits `FreeSegmentSlots` entries. There is one stack per slot count
/// (free_segment_slots_head[slot_count - 1]); the slot count must round-trip,
/// hence the explicit record.
fn emitFreeSegmentSlots(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, allocator: std.mem.Allocator) anyerror!void {
    const LinkContext = struct {
        core: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = page_ops.pageOf(current, constants.EDGE_SEGMENTS_PER_PAGE);
            const slot_idx = page_ops.slotOf(current, constants.EDGE_SEGMENTS_PER_PAGE);
            const raw: usize = self.core.edge_block_segment_reclamation_pages.load(page_idx);
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };

    var free_segment_slots: std.ArrayList(format.FreeSegmentSlots) = .empty;
    defer free_segment_slots.deinit(allocator);

    var slot_count: u16 = 1;
    while (slot_count <= constants.MAX_SEGMENTS_PER_NODE) : (slot_count += 1) {
        const slot_count_idx: usize = @intCast(slot_count - 1);
        const head: u64 = core.free_segment_slots_head[slot_count_idx].load(.acquire);
        const first_index = page_ops.stackHeadIndex(head);
        if (first_index == page_ops.EMPTY_INDEX) continue;

        const EmittingVisitor = struct {
            allocator: std.mem.Allocator,
            list: *std.ArrayList(format.FreeSegmentSlots),
            slot_count: u16,

            pub fn visit(self: *@This(), first_segment_idx: u32) !void {
                try self.list.append(self.allocator, .{
                    .first_segment = first_segment_idx,
                    .slot_count = self.slot_count,
                });
            }
        };

        var emitting_visitor = EmittingVisitor{ .allocator = allocator, .list = &free_segment_slots, .slot_count = slot_count };
        try page_ops.walkDetachedIndexStack(first_index, LinkContext{ .core = core }, &emitting_visitor);
    }

    if (free_segment_slots.items.len > 0) {
        try sink.emit(std.mem.sliceAsBytes(free_segment_slots.items));
    }
}

fn emitFreeTinyList(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide) anyerror!void {
    const head: u64 = switch (side) {
        .fwd => core.free_tiny_fwd_slot_head.load(.acquire),
        .rev => core.free_tiny_rev_slot_head.load(.acquire),
    };
    const first_index = page_ops.stackHeadIndex(head);
    if (first_index == page_ops.EMPTY_INDEX) return;

    const per_page: u32 = switch (side) {
        .fwd => node_tiny.TINY_FWD_SLOTS_PER_PAGE,
        .rev => node_tiny.TINY_REV_SLOTS_PER_PAGE,
    };

    const LinkContext = struct {
        core: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = page_ops.pageOf(current, per_page);
            const slot_idx = page_ops.slotOf(current, per_page);
            const raw: usize = switch (side) {
                .fwd => self.core.tiny_fwd_slot_reclamation_pages.load(page_idx),
                .rev => self.core.tiny_rev_slot_reclamation_pages.load(page_idx),
            };
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };

    var free_list: std.ArrayList(u32) = .empty;
    defer free_list.deinit(allocator);

    const EmittingVisitor = struct {
        allocator: std.mem.Allocator,
        list: *std.ArrayList(u32),

        pub fn visit(self: *@This(), index: u32) !void {
            try self.list.append(self.allocator, index);
        }
    };

    var emitting_visitor = EmittingVisitor{ .allocator = allocator, .list = &free_list };
    try page_ops.walkDetachedIndexStack(first_index, LinkContext{ .core = core }, &emitting_visitor);
    try sink.emit(std.mem.sliceAsBytes(free_list.items));
}

fn emitFreePropRows(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, allocator: std.mem.Allocator) anyerror!void {
    const head: u64 = core.free_prop_rows_head.load(.acquire);
    const first_index = page_ops.stackHeadIndex(head);
    if (first_index == page_ops.EMPTY_INDEX) return;

    const LinkContext = struct {
        core: *const graph_core.GraphCore,

        pub fn nextIndex(self: @This(), current: u32) !u32 {
            const page_idx = page_ops.pageOf(current, constants.PROP_ROWS_PER_PAGE);
            const slot_idx = page_ops.slotOf(current, constants.PROP_ROWS_PER_PAGE);
            const raw: usize = self.core.prop_row_reclamation_pages.load(page_idx);
            const reclamation_page: [*]const types.ReclamationEntry = @ptrFromInt(raw);
            return page_ops.reclamationNext(&reclamation_page[slot_idx]);
        }
    };

    var free_list: std.ArrayList(u32) = .empty;
    defer free_list.deinit(allocator);

    const EmittingVisitor = struct {
        allocator: std.mem.Allocator,
        list: *std.ArrayList(u32),

        pub fn visit(self: *@This(), index: u32) !void {
            try self.list.append(self.allocator, index);
        }
    };

    var emitting_visitor = EmittingVisitor{ .allocator = allocator, .list = &free_list };
    try page_ops.walkDetachedIndexStack(first_index, LinkContext{ .core = core }, &emitting_visitor);
    try sink.emit(std.mem.sliceAsBytes(free_list.items));
}

// ── Header / table serialization (pure, unit-testable) ───────────────────

/// Renders the header into its fixed HEADER_BYTES block: zero-fill, copy
/// the struct bytes, then compute format.headerChecksum over the block
/// (with the checksum field as zero) and patch it in.
pub fn serializeHeaderBlock(header: format.FileHeader, out: *[format.HEADER_BYTES]u8) void {
    @memset(out, 0);
    @memcpy(out[0..@sizeOf(format.FileHeader)], std.mem.asBytes(&header));
    const header_ptr: *format.FileHeader = @ptrCast(@alignCast(out));
    header_ptr.header_checksum = format.headerChecksum(out);
}

/// Renders the fixed section table (MAX_SECTIONS descriptors, in id order).
pub fn serializeSectionTable(table: *const [format.MAX_SECTIONS]format.SectionDescriptor, out: *[format.SECTION_TABLE_BYTES]u8) void {
    @memcpy(out, std.mem.asBytes(table));
}

comptime {
    // Modules the implementation will need; referencing them here documents
    // the dependency (same idiom as format.zig).
    _ = constants;
    _ = types;
    _ = page_ops;
    _ = node_access;
    _ = node_tiny;
    _ = rcu;
}
