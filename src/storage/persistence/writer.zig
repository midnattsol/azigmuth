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
/// precondition as `deinitChecked`). This function runs
/// `rcu.reclaimRetired` itself as step 0 so every retired
/// block/group/tiny-slot/prop-row has drained into the free structures.
pub fn save(core: *graph_core.GraphCore, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) SaveError!void {
    _ = core;
    _ = io;
    _ = dir;
    _ = sub_path;
    // TODO orchestration:
    //   0. rcu.reclaimRetired(core);
    //   1. var header = format.FileHeader.init(core);
    //   2. var plan = try planSections(core, header);
    //   3. hash pass: for each section, run emitSection into an
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
    _ = core;
    _ = header;
    // TODO:
    //   - fixed-shape sections: byte_len = format.expectedSectionBytes;
    //     entry_count = the page count (page sections) or node_count.
    //   - free-list sections: entry_count = countFreeStack(...), byte_len =
    //     entry_count * @sizeOf(u32) (or FreeGroupSpan for spans).
    //   - offsets: fold format.alignForward starting at
    //     format.PAYLOAD_BASE_OFFSET, skipping byte_len == 0 sections.
    @panic("TODO: planSections");
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
        .groups => emitGroupPages(core, sink),
        .tiny_fwd => emitTinyPages(core, sink, .fwd),
        .tiny_rev => emitTinyPages(core, sink, .rev),
        .free_blocks_fwd => emitFreeBlockList(core, sink, .fwd),
        .free_blocks_rev => emitFreeBlockList(core, sink, .rev),
        .free_group_spans => emitFreeGroupSpans(core, sink),
        .free_tiny_fwd => emitFreeTinyList(core, sink, .fwd),
        .free_tiny_rev => emitFreeTinyList(core, sink, .rev),
        .free_prop_rows => emitFreePropRows(core, sink),
    };
}

// ── Per-section emitters ─────────────────────────────────────────────────

/// Composes one `NodeRecord` per node (0..node_count) and emits them in
/// batches. The record is the published view normalized out of the RCU
/// double-buffers — see makeNodeRecord.
fn emitNodeRecords(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    // TODO: batch records into a small stack buffer (e.g. one
    // node-page worth) and sink.emit(std.mem.sliceAsBytes(batch)) per batch.
    @panic("TODO: emitNodeRecords");
}

/// Normalizes one node's published state into its canonical NodeRecord:
/// active SideAdj per direction (node_access / NodePublished), degrees,
/// next_local_edge_id (NodeHot), and the flag bits (removed,
/// needs_repair_*, sorted bits). Pure — unit-test it on its own.
pub fn makeNodeRecord(core: *const graph_core.GraphCore, node_idx: u32) format.NodeRecord {
    _ = core;
    _ = node_idx;
    @panic("TODO: makeNodeRecord");
}

/// Emits the raw `EdgeBlockFwd`/`EdgeBlockRev` pages, page-for-page, up to
/// the page containing block index `loadBlock*Count() - 1`
/// (format.blockPages). Whole pages are emitted, including slots past the
/// allocation frontier inside the last page.
fn emitBlockPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    _ = core;
    _ = sink;
    _ = side;
    // TODO: page_ops.edgeBlockPageRaw gives the page base as usize
    // (0 when absent — cannot happen below the frontier); slice it as
    // EDGE_BLOCKS_PER_PAGE blocks and emit its bytes.
    @panic("TODO: emitBlockPages");
}

/// Emits the u8 alive-count sidecar pages for `side`, same page walk as
/// emitBlockPages (page_ops.blockAlivePageRaw).
fn emitLivePages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    _ = core;
    _ = sink;
    _ = side;
    @panic("TODO: emitLivePages");
}

/// Emits `EdgeBlockFwdIds` pages (multigraph mode; otherwise emits nothing
/// — the planned byte_len is 0).
fn emitEdgeIdPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    @panic("TODO: emitEdgeIdPages");
}

/// Emits `EdgeBlockFwdProps` pages (edge_properties mode; otherwise nothing).
fn emitPropRowPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    @panic("TODO: emitPropRowPages");
}

/// Emits `EdgeBlockGroup` pages up to groupPages(loadGroupCount()).
fn emitGroupPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    @panic("TODO: emitGroupPages");
}

/// Emits Tiny{Fwd,Rev}Slot pages up to tiny*Pages(loadTiny*Count()).
fn emitTinyPages(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    _ = core;
    _ = sink;
    _ = side;
    @panic("TODO: emitTinyPages");
}

// ── Free-list emitters ───────────────────────────────────────────────────
//
// The free stacks are lock-free tagged stacks: the head lives in GraphCore
// (low 32 bits = first index, END_OF_CHAIN = empty) and the `next` links
// live in the per-entry meta pages. Walking them without mutating is safe
// under the quiesced-save contract, BUT the meta accessors are currently
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
    _ = core;
    _ = which;
    @panic("TODO: countFreeStack");
}

/// Emits the free block indices of `side` as raw u32s (drain order is
/// irrelevant — the loader just pushes them back).
fn emitFreeBlockList(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    _ = core;
    _ = sink;
    _ = side;
    @panic("TODO: emitFreeBlockList");
}

/// Emits `FreeGroupSpan` entries. There is one stack per span length
/// (free_group_spans_head[span_len - 1]); the span length must round-trip,
/// hence the explicit record.
fn emitFreeGroupSpans(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    @panic("TODO: emitFreeGroupSpans");
}

fn emitFreeTinyList(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink, comptime side: adjacency.AdjSide) anyerror!void {
    _ = core;
    _ = sink;
    _ = side;
    @panic("TODO: emitFreeTinyList");
}

fn emitFreePropRows(core: *const graph_core.GraphCore, sink: io_mod.PayloadSink) anyerror!void {
    _ = core;
    _ = sink;
    @panic("TODO: emitFreePropRows");
}

// ── Header / table serialization (pure, unit-testable) ───────────────────

/// Renders the header into its fixed HEADER_BYTES block: zero-fill, copy
/// the struct bytes, then compute format.headerChecksum over the block
/// (with the checksum field as zero) and patch it in.
pub fn serializeHeaderBlock(header: format.FileHeader, out: *[format.HEADER_BYTES]u8) void {
    _ = header;
    _ = out;
    @panic("TODO: serializeHeaderBlock");
}

/// Renders the fixed section table (MAX_SECTIONS descriptors, in id order).
pub fn serializeSectionTable(table: *const [format.MAX_SECTIONS]format.SectionDescriptor, out: *[format.SECTION_TABLE_BYTES]u8) void {
    _ = table;
    _ = out;
    @panic("TODO: serializeSectionTable");
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
