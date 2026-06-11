//! Acceptance tests for the persistence stack (SKELETON). Every test starts
//! skipped; flip each `return error.SkipZigTest;` into a real body as its
//! piece lands. The test names ARE the acceptance criteria — a module is
//! done when its block of tests passes un-skipped.

const std = @import("std");
const graph_mod = @import("graph_mod");

const persistence = graph_mod.persistence_mod;
const writer = persistence.writer;
const loader = persistence.loader;
const frozen = persistence.frozen;

// Force full semantic analysis of the skeletons even while nothing calls
// them (Zig analyzes lazily; this keeps the stubs honest from day one).
test "persistence: skeletons compile" {
    std.testing.refAllDecls(persistence);
    std.testing.refAllDecls(persistence.io);
    std.testing.refAllDecls(writer);
    std.testing.refAllDecls(loader);
    std.testing.refAllDecls(frozen);
    std.testing.refAllDecls(frozen.FrozenGraph);
}

// ── writer ───────────────────────────────────────────────────────────────
// Build a small but representative graph for all of these: a few nodes with
// block adjacency, one tiny node, grouped runs if cheap, some removeEdge
// churn so the free stacks are non-empty, then reclaim + save into
// std.testing.tmpDir.

test "save: produces a file whose header and section table validate" {
    // Criteria: read raw bytes back; parse FileHeader; validateHeader and
    // validateSectionTable pass; counters match the live graph.
    return error.SkipZigTest;
}

test "save: every section checksum matches its payload" {
    // Criteria: for each descriptor, sectionChecksum(payload) == checksum.
    return error.SkipZigTest;
}

test "save: a flipped payload byte is detected by its section checksum" {
    // Criteria: flip one byte inside a NON-EMPTY section (pick by
    // byte_len > 0 — section 1 can be empty on tiny graphs), recompute,
    // expect mismatch.
    return error.SkipZigTest;
}

test "save: failure leaves no tmp file behind" {
    // Criteria: force a failure mid-save (e.g. failing allocator for the
    // plan) and assert the directory contains neither target nor tmp.
    return error.SkipZigTest;
}

test "save: makeNodeRecord normalizes published state" {
    // Criteria (pure unit test, no I/O): node with edges → record degrees,
    // SideAdj, sorted bits and flags match the published view; removed
    // node → removed flag set.
    return error.SkipZigTest;
}

// ── loader ───────────────────────────────────────────────────────────────

test "load: round-trip preserves counts, degrees and neighbor sets" {
    // Criteria: save → load → nodeCount/edgeCount equal; for every node,
    // out/in degree and the sorted neighbor list equal the original; loaded
    // graph passes validate().
    return error.SkipZigTest;
}

test "load: round-trip graph stays fully mutable" {
    // Criteria: after load, addNode/addEdge/removeEdge work and reuse the
    // restored free lists (storage stats show recycling, not fresh growth).
    return error.SkipZigTest;
}

test "load: multigraph and properties flags round-trip" {
    // Criteria: save a multigraph+properties graph; load derives the
    // options from the header; edge ids and prop rows survive.
    return error.SkipZigTest;
}

test "load: rejects bad magic" {
    return error.SkipZigTest;
}

test "load: rejects incompatible format params" {
    // Criteria: corrupt the params bytes (then re-patch the header checksum
    // so ONLY the params check can fire) → IncompatibleFormatParams.
    return error.SkipZigTest;
}

test "load: rejects truncation at every section boundary" {
    // Criteria: for each section, truncate the file just before its end →
    // TruncatedFile (or checksum failure), never a crash or a half-loaded
    // graph.
    return error.SkipZigTest;
}

test "load: rejects a flipped bit in each section" {
    // Criteria: loop sections with byte_len > 0, flip one bit, expect
    // CorruptSection; original file still loads after restoring the bit.
    return error.SkipZigTest;
}

test "load: rejects hostile indices that pass checksums" {
    // Criteria: craft a record/free-entry index past its frontier, re-hash
    // the section so checksums are VALID, expect CorruptIndex — proves
    // bounds-checking is independent of integrity checking.
    return error.SkipZigTest;
}

// ── frozen mmap ──────────────────────────────────────────────────────────

test "frozen: open serves counts, degrees and neighbors equal to the live graph" {
    // Criteria: save → FrozenGraph.open → nodeCount/edgeCount/degrees and
    // neighbor iteration match the source graph for every node (tiny,
    // contiguous and grouped sides all covered).
    return error.SkipZigTest;
}

test "frozen: open with verify_checksums rejects a tampered file" {
    return error.SkipZigTest;
}

test "frozen: mapping survives the snapshot being replaced by rename" {
    // Criteria: open frozen → save a NEW snapshot over the same path
    // (rename) → the open FrozenGraph still answers identically (inode
    // pinned by the mapping); re-open sees the new graph.
    return error.SkipZigTest;
}

test "frozen: concurrent readers need no coordination" {
    // Criteria: N threads iterate neighbors over the same FrozenGraph;
    // results identical; no tokens/epochs involved.
    return error.SkipZigTest;
}
