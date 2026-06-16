# The azigmuth File Format

| | |
|---|---|
| Magic | `AZMTHRB1` (`0x3142_5248_544D_5A41` as little-endian u64) |
| Format version | **1.0** (major 1, minor 0) |
| Status | Specification stable; reference implementation in progress |

This document is the normative specification of the azigmuth on-disk graph
snapshot format. It is self-contained: a conforming reader or writer can be
implemented in any language from this document alone. The key words MUST,
MUST NOT, SHOULD and MAY are to be interpreted as in RFC 2119.

The format serializes one RB-CSR directed graph — topology, per-edge
relation labels, optional edge ids and property-row keys — as a single
file. Property *values* are out of scope by design: azigmuth composes with
columnar stores through the stable ids this format preserves.

---

## 1. Design goals

1. **Zero-copy reads.** The bulk of the file (edge storage) is the engine's
   exact in-memory page layout, 64-byte aligned, so a read-only graph can be
   served directly from an `mmap` of the file with no deserialization.
2. **Embedded-friendly.** Fixed-size header, fixed-size section table, no
   variable-length metadata to parse; a reader needs no allocator to
   validate a file.
3. **Integrity by construction.** Every byte is covered by a checksum
   (header or per-section), verifiable independently and lazily.
4. **Atomic publication.** A snapshot file is always complete and
   self-consistent; the write protocol (§10) guarantees a reader can never
   observe a partial file under the final name.
5. **Honest compatibility.** A file is either exactly loadable or exactly
   rejected — never reinterpreted (§9).

## 2. Conventions

- **Endianness.** All multi-byte integers are **little-endian**. A
  big-endian implementation MUST byte-swap; it MUST NOT write a big-endian
  variant.
- **Alignment.** `SECTION_ALIGN` = 64 bytes. Every non-empty section
  payload starts at a file offset that is a multiple of 64. Combined with
  page-aligned `mmap` bases, this guarantees that every structure below can
  be referenced in place at its natural alignment.
- **Page.** Engine storage is pooled in fixed-capacity pages. Page
  sections are written page-for-page; the last page is written whole even
  when partially used (§7.2).
- **Reserved fields.** All `_reserved`/padding bytes MUST be written as
  zero. Readers MUST NOT assign them meaning in version 1.x.
- **Counts vs frontiers.** Header counters are allocation frontiers
  (total ever allocated), not live counts; free lists (§7.7) record which
  allocated entries are currently reusable.

## 3. File anatomy

```
offset 0                                          ┐
  FileHeader            (80 bytes used)           │ 512-byte header block,
  zero padding          (432 bytes)               │ checksummed as a whole
offset 512                                        ┘
  SectionDescriptor[16] (16 × 32 = 512 bytes)       fixed section table
offset 1024 = PAYLOAD_BASE_OFFSET (64-aligned)
  section payloads, in table order, each 64-aligned,
  zero padding between payloads as required
EOF
```

There is no footer; the section table fully determines the extent of every
payload, and `max(file_offset + byte_len)` determines the minimum file
length.

## 4. FileHeader

The header occupies a fixed 512-byte block (`HEADER_BYTES`). The struct is
80 bytes; bytes 80..511 are zero (reserved for minor-version additions) and
are covered by the header checksum.

| Offset | Size | Field | Type | Description |
|---|---|---|---|---|
| 0 | 8 | `magic` | u64 | `0x3142_5248_544D_5A41` ("AZMTHRB1") |
| 8 | 2 | `version_major` | u16 | breaking format revision; this spec: 1 |
| 10 | 2 | `version_minor` | u16 | additive revision; this spec: 0 |
| 12 | 2 | `flags` | GraphFlags | feature flags, §5.1 |
| 14 | 2 | `section_count` | u16 | MUST be 16 in v1 |
| 16 | 12 | `params` | FormatParams | layout parameters, §5.2 |
| 28 | 4 | — | padding | MUST be zero |
| 32 | 8 | `node_count` | u64 | nodes ever allocated (ids 0..count-1) |
| 40 | 8 | `edge_count` | u64 | live edge count |
| 48 | 4 | `block_fwd_count` | u32 | forward edge-block frontier |
| 52 | 4 | `block_rev_count` | u32 | reverse edge-block frontier |
| 56 | 4 | `group_count` | u32 | group-descriptor frontier |
| 60 | 4 | `tiny_block_fwd_count` | u32 | tiny forward slot frontier |
| 64 | 4 | `tiny_block_rev_count` | u32 | tiny reverse slot frontier |
| 68 | 4 | `prop_row_count` | u32 | property-row frontier (row 0 reserved = "none") |
| 72 | 8 | `header_checksum` | u64 | §8.1 |
| 80 | 432 | — | reserved | MUST be zero |

### 4.1 GraphFlags (u16 bitfield)

| Bit | Name | Meaning |
|---|---|---|
| 0 | `multigraph` | parallel edges allowed; section 5 present |
| 1 | `edge_properties` | stable property rows; sections 6 and 15 present |
| 2–15 | reserved | MUST be zero |

## 5. Compatibility parameters

### 5.2 FormatParams (12 bytes at header offset 16)

These parameters are compile-time storage-profile choices that change the
byte layout of pages or the meaning of indices. **A file is loadable only
by an implementation whose own parameters are byte-identical** (§9).

| Offset | Size | Field | Default profile |
|---|---|---|---|
| 0 | 2 | `edges_per_block` (EPB) | 64 |
| 2 | 2 | `nodes_per_page` | 256 |
| 4 | 2 | `edge_blocks_per_page` (BPP) | 64 |
| 6 | 2 | `edge_groups_per_page` (GPP) | 128 |
| 8 | 1 | `tiny_fwd_cap_simple` | 8 |
| 9 | 1 | `tiny_fwd_cap_multi` | 4 |
| 10 | 1 | `tiny_rev_cap` | 16 |
| 11 | 1 | reserved | 0 |

## 6. Section table

16 descriptors of 32 bytes each, at offset 512, **in section-id order**
(descriptor *i* MUST have `id == i`).

| Offset | Size | Field | Type | Description |
|---|---|---|---|---|
| 0 | 2 | `id` | u16 | section id, §7 |
| 2 | 2 | — | reserved | MUST be zero |
| 4 | 4 | `entry_count` | u32 | logical elements: pages for page sections, records/indices otherwise |
| 8 | 8 | `file_offset` | u64 | absolute payload offset; 64-aligned |
| 16 | 8 | `byte_len` | u64 | payload length in bytes |
| 24 | 8 | `checksum` | u64 | §8.2 |

Rules (all MUST):

- An **absent** optional section keeps its table slot with `byte_len == 0`
  and `entry_count == 0`; its `file_offset` is then meaningless and ignored.
- Non-empty payloads are mutually non-overlapping, at offsets `>= 1024`,
  monotonically increasing in table order.
- For fixed-shape sections, `byte_len` MUST equal the derived size in §7;
  for free-list sections, `byte_len == entry_count × entry_size`.

## 7. Section catalog

Page-count derivation used throughout: `pages(n, per) = ceil(n / per)`.

| Id | Name | Element | Element size | Present |
|---|---|---|---|---|
| 0 | `node_records` | NodeRecord | 48 | always |
| 1 | `blocks_fwd` | EdgeBlockFwd page | BPP × 8·EPB | always |
| 2 | `blocks_rev` | EdgeBlockRev page | BPP × 4·EPB | always |
| 3 | `alive_fwd` | u8 per block slot | BPP × 1 | always |
| 4 | `alive_rev` | u8 per block slot | BPP × 1 | always |
| 5 | `edge_ids_fwd` | EdgeBlockFwdIds page | BPP × 4·EPB | iff `multigraph` |
| 6 | `prop_rows_fwd` | EdgeBlockFwdProps page | BPP × 4·EPB | iff `edge_properties` |
| 7 | `groups` | EdgeBlockGroup page | GPP × 8 | always |
| 8 | `tiny_fwd` | TinyFwdSlot page | 256 × 128 | always |
| 9 | `tiny_rev` | TinyRevSlot page | 256 × 64 | always |
| 10 | `free_blocks_fwd` | u32 block index | 4 | always |
| 11 | `free_blocks_rev` | u32 block index | 4 | always |
| 12 | `free_group_spans` | FreeGroupSpan | 8 | always |
| 13 | `free_tiny_fwd` | u32 slot index | 4 | always |
| 14 | `free_tiny_rev` | u32 slot index | 4 | always |
| 15 | `free_prop_rows` | u32 row id | 4 | iff `edge_properties` |

Byte lengths of the page sections (ids 1–9) derive from the header
frontiers: e.g. `blocks_fwd` = `pages(block_fwd_count, BPP) × BPP × 8·EPB`.
Sections 3–4 use the same page count as their block section (one byte per
block slot, page-for-page). Sections 8–9 use 256 slots per page. "Always"
sections may still be empty (`byte_len 0`) when their frontier is zero.

### 7.1 node_records (id 0) — NodeRecord, 48 bytes

One record per node id in `[0, node_count)`, in id order. The record is the
node's *published* state, normalized out of the engine's RCU double
buffers (only the active version survives a save).

| Offset | Size | Field | Type |
|---|---|---|---|
| 0 | 16 | `fwd` | SideAdj (outgoing side) |
| 16 | 16 | `rev` | SideAdj (incoming side) |
| 32 | 4 | `degree_fwd` | u32 |
| 36 | 4 | `degree_rev` | u32 |
| 40 | 4 | `next_local_edge_id` | u32 (multigraph id allocator cursor; starts at 1) |
| 44 | 2 | `flags` | NodeRecordFlags |
| 46 | 2 | — | reserved, zero |

**NodeRecordFlags (u16):** bit 0 `removed`, bit 1 `needs_repair_fwd`,
bit 2 `needs_repair_rev`, bit 3 `fwd_sorted`, bit 4 `rev_sorted`; bits
5–15 reserved, zero. A `removed` node's record MUST carry empty sides and
zero degrees.

**SideAdj, 16 bytes** — the adjacency descriptor of one direction:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `first_block` (u32) |
| 4 | 4 | `block_count` (u32) |
| 8 | 2 | `group_count` (u16) |
| 10 | 2 | padding, zero |
| 12 | 4 | `first_group` (u32) |

Four encodings, discriminated in this order:

1. **Tiny** — `block_count` bit 31 (`0x8000_0000`) set: the side lives in a
   tiny slot. `first_block` = tiny slot index (into section 8 or 9);
   `block_count & 0x7FFF_FFFF` = entry count; `group_count` and
   `first_group` MUST be zero. Capacity bound: `tiny_*_cap` params.
2. **Empty** — `block_count == 0 && group_count == 0`: no edges;
   `first_block`/`first_group` are meaningless and SHOULD be zero.
3. **Contiguous** — `group_count == 0, block_count > 0`: one physical run
   of `block_count` consecutive block indices starting at `first_block`.
4. **Grouped** — `group_count ∈ [1, 4]`: the side is `group_count`
   consecutive EdgeBlockGroup descriptors starting at `first_group`
   (section 7), each describing one run. 4 is a hard format bound (the
   read-amplification invariant).

### 7.2 blocks_fwd / blocks_rev (ids 1–2) — edge blocks

Blocks are indexed globally; block index *b* lives in page `b / BPP`, slot
`b % BPP`. Pages are written in index order; the entire last page is
written (slots at or beyond the frontier are unspecified bytes — readers
MUST NOT interpret them, but they ARE covered by the section checksum).

**EdgeBlockFwd** (8·EPB bytes, 64-aligned) — structure-of-arrays:

| Offset | Size | Field |
|---|---|---|
| 0 | 4·EPB | `destinations: [EPB]u32` |
| 4·EPB | 2·EPB | `relations: [EPB]u16` |
| 6·EPB | 2·EPB | `flags: [EPB]u16` (per-edge flags; all bits reserved, zero, in v1) |

**EdgeBlockRev** (4·EPB bytes, 64-aligned): `sources: [EPB]u32`.

**Dense contract:** in every block, entries `[0, live)` are the valid ones
— `live` comes from the live sidecar (§7.3) — and entries at `[live, EPB)`
are unspecified. A block whose side has the sorted flag set holds its live
destinations in ascending order, and consecutive blocks of that side are
ordered across block boundaries.

### 7.3 alive_fwd / alive_rev (ids 3–4)

One u8 per block slot, page-for-page parallel to ids 1–2: the live entry
count of the corresponding block, in `[0, EPB]`.

### 7.4 edge_ids_fwd (id 5) and prop_rows_fwd (id 6)

Sidecar pages parallel to `blocks_fwd`, 4·EPB bytes per block:
`[EPB]u32`. Slot *i* annotates forward entry *i* of the same block index —
the multigraph edge id (id 5) or the stable property row (id 6, 0 = none).
Tiny sides carry these inline (§7.6) instead.

### 7.5 groups (id 7) — EdgeBlockGroup, 8 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `start` (u32) — first block index of the run |
| 4 | 4 | `count` (u32) — blocks in the run |

### 7.6 tiny_fwd / tiny_rev (ids 8–9)

Small adjacencies bypass blocks. 256 slots per page.

**TinyFwdSlot** = `[tiny_fwd_cap_simple]TinyFwdEntry` (8 × 16 = 128 bytes).
In multigraph mode only the first `tiny_fwd_cap_multi` entries are usable;
the slot size does not change. **TinyFwdEntry, 16 bytes:**

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `destination` (u32) |
| 4 | 2 | `relation` (u16) |
| 6 | 2 | `flags` (u16, reserved) |
| 8 | 4 | `edge_id` (u32; 0 outside multigraph) |
| 12 | 4 | `prop_row` (u32; 0 = none) |

**TinyRevSlot** = `[tiny_rev_cap]u32` source ids (16 × 4 = 64 bytes).

Entries `[0, tiny count)` (count from the SideAdj) are valid and sorted by
destination (fwd) / source (rev); the rest are unspecified.

### 7.7 Free lists (ids 10–15)

Raw arrays of reusable indices drained from the engine's free structures,
in unspecified order. `FreeGroupSpan` (8 bytes): `first_group` u32 @0,
`span_count` u16 @4 (in `[1, 4]`), reserved u16 @6 zero. Every index MUST
be below its corresponding header frontier, MUST NOT be referenced by any
NodeRecord, and MUST NOT appear twice (across the section).

## 8. Integrity

All checksums are **XxHash64 with seed `0x3142_5248_544D_5A41`** (the
magic).

### 8.1 Header checksum

Computed over the full 512-byte header block with the 8 bytes of
`header_checksum` (offsets 72..79) treated as zero. This covers the
reserved tail, so future minor versions cannot smuggle unchecksummed bytes.

### 8.2 Section checksums

`checksum` = XxHash64(seed, payload bytes) over the exact
`[file_offset, file_offset + byte_len)` range. Empty sections carry the
hash of the empty input. Padding between sections is NOT checksummed and
MUST be ignored by readers (writers MUST emit zeros).

## 9. Compatibility and evolution

- **Magic/major:** a reader MUST reject a wrong magic, and MUST reject
  `version_major != 1` for this spec.
- **Minor:** minor revisions may only (a) define currently-reserved header
  bytes/flag bits, (b) define meaning for currently-unspecified bytes in
  ways old readers can safely ignore. A v1.0 reader MAY load any v1.x file.
- **Params equality:** a reader MUST compare all 12 bytes of FormatParams
  with its own and reject on any difference (`edges_per_block` changes the
  byte layout of every block; the others change index meanings). There is
  no translation mode in v1.
- **Unknown anything ⇒ rejection.** Nonzero reserved fields, section ids
  out of order, sizes that do not match the derivations: a conforming
  reader rejects rather than guesses. Forward compatibility is explicit
  failure, never misexecution.

## 10. Writer requirements

1. The graph MUST be quiesced (no concurrent mutators, readers or
   repairers) and retired storage MUST be fully reclaimed before
   serialization — retired state is not representable in the file.
2. Sides are written normalized: the published version of each SideAdj;
   RCU staging buffers and version counters are not persisted.
3. The file MUST be written to a temporary name **in the same directory**,
   flushed, fsync'd, and atomically renamed over the final name. The final
   name MUST never refer to a partial file. (Directory fsync afterwards is
   RECOMMENDED for durability of the rename itself.)
4. All padding/reserved bytes MUST be zero.

## 11. Reader requirements

Validation ladder, in order, before trusting any payload byte:

1. read the 512-byte header block; check magic, major, params equality,
   `section_count == 16`, header checksum;
2. read the section table; check id order, derived sizes, alignment,
   monotonic non-overlapping offsets;
3. check every `file_offset + byte_len` against the real file length
   (truncation);
4. verify section checksums — eagerly, or lazily per section before first
   use;
5. only then materialize (copy into mutable structures) or map (serve
   read-only in place).

A checksum proves integrity, not honesty: a well-checksummed file can
still claim out-of-bounds indices. Readers MUST bounds-check every index
read from payloads (block/group/tiny/row indices against the header
frontiers; destinations/sources against `node_count`) before use.

In-place (mmap) readers additionally rely on §2 alignment: every
structure's natural alignment divides 64, and 64 divides every non-empty
`file_offset`, so casting mapped bytes to the structures above is sound.

## 12. Security considerations

A snapshot file is untrusted input. Beyond §11: readers MUST decode enums
and bitfields defensively (reserved bits zero), MUST NOT allocate based on
unvalidated sizes (derive sizes from the header and compare, never trust
`byte_len` alone), and SHOULD treat unspecified bytes (beyond-frontier
slots, beyond-live entries) as opaque — never as data, even after
checksums pass.

## 13. Reserved for future revisions

Block compression (delta-encoded destinations), additional section ids
(16+ would require a major bump since `section_count` is fixed at 16 in
v1), CRC alternatives, and big-endian variants are all explicitly out of
v1. The 432-byte header tail and the reserved flag/field bits are the
designated extension space for minor revisions.
