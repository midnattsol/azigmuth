//! Persistence facade. One import point for the whole snapshot
//! stack; the pieces live in `persistence/`:
//!
//!   - `format` — the pure on-disk layout: sections, sizes, checksums,
//!     validators. No I/O. The normative save/load contracts live in its
//!     module doc.
//!   - `validation` — shared hostile-input validation ladder (loader + frozen).
//!   - `writer` — serialize a quiesced graph, tmp + fsync + rename.
//!   - `loader` — validate + reconstruct a fully mutable graph.
//!   - `frozen` — zero-copy read-only graph over an mmap.
//!
//! The format's symbols are re-exported flat so `persistence.FileHeader`
//! and friends keep working as before the split.

pub const format = @import("persistence/format.zig");
pub const validation = @import("persistence/validation.zig");
pub const writer = @import("persistence/writer.zig");
pub const loader = @import("persistence/loader.zig");
pub const frozen = @import("persistence/frozen.zig");

// ── Flat re-exports of the format (the pre-split public surface) ─────────

pub const MAGIC = format.MAGIC;
pub const FORMAT_VERSION_MAJOR = format.FORMAT_VERSION_MAJOR;
pub const FORMAT_VERSION_MINOR = format.FORMAT_VERSION_MINOR;
pub const HEADER_BYTES = format.HEADER_BYTES;
pub const SECTION_ALIGN = format.SECTION_ALIGN;
pub const SectionId = format.SectionId;
pub const MAX_SECTIONS = format.MAX_SECTIONS;
pub const SECTION_TABLE_OFFSET = format.SECTION_TABLE_OFFSET;
pub const SECTION_TABLE_BYTES = format.SECTION_TABLE_BYTES;
pub const PAYLOAD_BASE_OFFSET = format.PAYLOAD_BASE_OFFSET;
pub const FormatParams = format.FormatParams;
pub const GraphFlags = format.GraphFlags;
pub const FileHeader = format.FileHeader;
pub const HeaderError = format.HeaderError;
pub const validateHeader = format.validateHeader;
pub const SectionDescriptor = format.SectionDescriptor;
pub const NodeRecord = format.NodeRecord;
pub const FreeSegmentSlots = format.FreeSegmentSlots;
pub const alignForward = format.alignForward;
pub const blockPages = format.blockPages;
pub const segmentPages = format.segmentPages;
pub const tinyFwdPages = format.tinyFwdPages;
pub const tinyRevPages = format.tinyRevPages;
pub const expectedSectionBytes = format.expectedSectionBytes;
pub const SectionTableError = format.SectionTableError;
pub const validateSectionTable = format.validateSectionTable;
pub const Hasher = format.Hasher;
pub const initHasher = format.initHasher;
pub const sectionChecksum = format.sectionChecksum;
pub const headerChecksum = format.headerChecksum;
