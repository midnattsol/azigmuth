//! Shared validation/parsing for the persistence stack.
//!
//! Everything here is consumed by more than one sibling:
//!  - the validation ladder: `loader.load` and `frozen.FrozenGraph.open`
//!    segment the exact same hostile-input checks (header → table → length →
//!    checksums) before trusting a single payload byte; only the
//!    materialization differs (copy vs map).

const std = @import("std");
const format = @import("format.zig");

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
