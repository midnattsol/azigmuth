//! Shared byte-level plumbing for the persistence stack.
//!
//! Everything here is consumed by more than one sibling:
//!  - the payload sinks: the writer's hash pass and write pass stream the
//!    same bytes through the same `PayloadSink` interface, so checksums
//!    cannot diverge from what lands on disk;
//!  - the validation ladder: `loader.load` and `frozen.FrozenGraph.open`
//!    segment the exact same hostile-input checks (header → table → length →
//!    checksums) before trusting a single payload byte; only the
//!    materialization differs (copy vs map).

const std = @import("std");
const format = @import("format.zig");

// ── Payload sinks (writer side) ──────────────────────────────────────────

/// Minimal byte sink: the hash pass and the file pass both consume payloads
/// through this interface, guaranteeing they observe identical bytes.
pub const PayloadSink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn emit(self: PayloadSink, bytes: []const u8) anyerror!void {
        return self.emitFn(self.ctx, bytes);
    }
};

/// Sink that feeds an XxHash64 (seeded like format.sectionChecksum).
pub const HashingSink = struct {
    hasher: std.hash.XxHash64,

    pub fn init() HashingSink {
        return .{ .hasher = std.hash.XxHash64.init(format.MAGIC) };
    }

    pub fn sink(self: *HashingSink) PayloadSink {
        const HashEmit = struct {
            fn emit(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                const hash_sink: *HashingSink = @ptrCast(@alignCast(ctx));
                hash_sink.hasher.update(bytes);
            }
        };
        return .{ .ctx = self, .emitFn = HashEmit.emit };
    }

    pub fn digest(self: *HashingSink) u64 {
        return self.hasher.final();
    }
};

/// Buffered file sink.
pub const FileSink = struct {
    file: std.fs.File,
    io: std.Io,
    writer: std.Io.File.Writer,
    bytes_written: u64 = 0,

    pub fn init(file: std.fs.File, io: std.Io) FileSink {
        return .{
            .file = file,
            .io = io,
            .writer = file.writer(io),
        };
    }

    pub fn sink(self: *FileSink) PayloadSink {
        const FileEmit = struct {
            fn emit(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                const file_sink: *FileSink = @ptrCast(@alignCast(ctx));
                try file_sink.writer.writeAll(bytes);
                file_sink.bytes_written += bytes.len;
            }
        };
        return .{ .ctx = self, .emitFn = FileEmit.emit };
    }

    pub fn padTo(self: *FileSink, target: u64) !void {
        if (target <= self.bytes_written) return;
        const zero_buf: [64]u8 = [_]u8{0} ** 64;
        var remaining = target - self.bytes_written;
        while (remaining > 0) {
            const chunk = @min(remaining, zero_buf.len);
            try self.writer.writeAll(zero_buf[0..chunk]);
            remaining -= chunk;
        }
        self.bytes_written = target;
    }

    pub fn flush(self: *FileSink) !void {
        try self.writer.flush();
    }
};

// ── Validation ladder (loader + frozen side) ─────────────────────────────
//
// Hostile-parsing discipline (normative): the file is adversarial input
// until proven otherwise — NOTHING from the payload is dereferenced, sized,
// or trusted before these pass, in this order.

pub const ValidateError = format.HeaderError || format.SectionTableError || error{
    TruncatedFile,
    CorruptSection,
    InvalidPayload,
    Overflow,
};

/// Reinterprets the raw header block, then
/// `format.validateHeader` (magic, version, params vs the running comptime
/// profile, header checksum).
pub fn parseHeader(raw_header_block: *const [format.HEADER_BYTES]u8) ValidateError!format.FileHeader {
    var header: format.FileHeader = undefined;
    @memcpy(std.mem.asBytes(&header), raw_header_block[0..@sizeOf(format.FileHeader)]);
    try format.validateHeader(header, raw_header_block);
    return header;
}

/// Reinterprets and validates the fixed section table.
pub fn parseSectionTable(
    header: format.FileHeader,
    raw_table: *const [format.SECTION_TABLE_BYTES]u8,
) ValidateError![format.MAX_SECTIONS]format.SectionDescriptor {
    var table: [format.MAX_SECTIONS]format.SectionDescriptor = undefined;
    @memcpy(std.mem.asBytes(&table), raw_table);
    try format.validateSectionTable(header, &table);
    return table;
}

/// Every section must fit inside the real file
/// (offset + byte_len <= file_len), or the file was truncated.
pub fn checkSectionsAgainstFileLen(table: *const [format.MAX_SECTIONS]format.SectionDescriptor, file_len: u64) ValidateError!void {
    for (table.*) |descriptor| {
        if (descriptor.byte_len == 0) continue;
        const end = try std.math.add(u64, descriptor.file_offset, descriptor.byte_len);
        if (file_len < end) return error.TruncatedFile;
    }
}

/// Per section: payload bytes vs the descriptor checksum.
pub fn verifySectionChecksum(descriptor: format.SectionDescriptor, payload: []const u8) ValidateError!void {
    if (payload.len != descriptor.byte_len) return error.InvalidPayload;
    if (format.sectionChecksum(payload) != descriptor.checksum) return error.CorruptSection;
}
