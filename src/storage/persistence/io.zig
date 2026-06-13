//! Shared byte-level plumbing for the persistence stack (SKELETON).
//!
//! Everything here is consumed by more than one sibling:
//!  - the payload sinks: the writer's hash pass and write pass stream the
//!    same bytes through the same `PayloadSink` interface, so checksums
//!    cannot diverge from what lands on disk;
//!  - the validation ladder: `loader.load` and `frozen.FrozenGraph.open`
//!    run the exact same hostile-input checks (header → table → length →
//!    checksums) before trusting a single payload byte; only the
//!    materialization differs (copy vs map).

const std = @import("std");
const format = @import("format.zig");

// ── Payload sinks (writer side) ──────────────────────────────────────────

/// Minimal byte sink: the hash pass and the file pass both consume payloads
/// through this interface, guaranteeing they observe identical bytes.
pub const PayloadSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn emit(self: PayloadSink, bytes: []const u8) anyerror!void {
        return self.emitFn(self.context, bytes);
    }
};

/// Sink that feeds an XxHash64 (seeded like format.sectionChecksum).
pub const HashingSink = struct {
    hasher: std.hash.XxHash64,

    pub fn init() HashingSink {
        // TODO: seed with the same seed sectionChecksum uses (the
        // MAGIC); expose a digest() that returns hasher.final().
        @panic("TODO: HashingSink.init");
    }

    pub fn sink(self: *HashingSink) PayloadSink {
        _ = self;
        @panic("TODO: HashingSink.sink");
    }
};

/// Buffered file sink. Tracks bytes written so the writer can assert that
/// each section landed exactly at its planned offset with its planned
/// length.
pub const FileSink = struct {
    // TODO: hold the std.Io.File.Writer (file.writer(io, buffer))
    // plus a running byte counter; provide sink(), padTo(offset) — emit
    // zeros up to an absolute offset — and flush().
    bytes_written: u64 = 0,

    pub fn sink(self: *FileSink) PayloadSink {
        _ = self;
        @panic("TODO: FileSink.sink");
    }
};

// ── Validation ladder (loader + frozen side) ─────────────────────────────
//
// Hostile-parsing discipline (normative): the file is adversarial input
// until proven otherwise — NOTHING from the payload is dereferenced, sized,
// or trusted before these pass, in this order.

// TODO: narrow (format.HeaderError || format.SectionTableError ||
// error{TruncatedFile, CorruptSection} || read errors).
pub const ValidateError = anyerror;

/// Reinterprets the raw header block, then
/// `format.validateHeader` (magic, version, params vs the running comptime
/// profile, header checksum).
pub fn parseHeader(raw_header_block: *const [format.HEADER_BYTES]u8) ValidateError!format.FileHeader {
    const header: format.FileHeader = undefined;
    @memcpy(std.mem.asBytes(&header), raw_header_block[0..@sizeOf(format.FileHeader)]);
    try format.validateHeader(header, raw_header_block);
    return header;
}

/// Reinterprets and validates the fixed section table.
pub fn parseSectionTable(
    header: format.FileHeader,
    raw_table: *const [format.SECTION_TABLE_BYTES]u8,
) ValidateError![format.MAX_SECTIONS]format.SectionDescriptor {
    const table: [format.MAX_SECTIONS]format.SectionDescriptor = undefined;
    @memcpy(std.mem.asBytes(&table), raw_table);
    try format.validateSectionTable(header, &table);
    return table;
}

/// Every section must fit inside the real file
/// (offset + byte_len <= file_len), or the file was truncated.
pub fn checkSectionsAgainstFileLen(table: *const [format.MAX_SECTIONS]format.SectionDescriptor, file_len: u64) ValidateError!void {
    for (table.*) |descriptor| {
        if (descriptor.byte_len == 0) continue;
        const end = try std.math.add(descriptor.file_offset, descriptor.byte_len);
        if (file_len < end) return error.TruncatedFile;
    }
}

/// Per section: payload bytes vs the descriptor checksum.
pub fn verifySectionChecksum(descriptor: format.SectionDescriptor, payload: []const u8) ValidateError!void {
    if (payload.len != descriptor.byte_len) return error.InvalidPayload;
    if (format.sectionChecksum(payload) != descriptor.checksum) return error.CorruptSection;
}
