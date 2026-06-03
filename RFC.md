# RFC-0001 — RB-CSR: Read-Budgeted Compressed Sparse Row

| Field          | Value                                          |
|----------------|------------------------------------------------|
| **RFC**        | 0001                                           |
| **Title**      | RB-CSR Graph Storage Engine                    |
| **Status**     | Draft — Phase 2 implementation in progress     |
| **Author**     | —                                              |
| **Date**       | 2026-05-30                                     |
| **Supersedes** | —                                              |
| **Scope**      | Core storage format, mutation model, concurrency model, validation model, phased implementation plan |

---

## Abstract

RB-CSR (Read-Budgeted Compressed Sparse Row) is a directed-graph storage architecture that bounds traversal degradation under continuous mutation. Each node's adjacency is stored as a sequence of fixed-size blocks with occupancy masks. Edges are sorted by destination within each block. Reverse adjacency is maintained via a compact secondary block pool. Per-node RCU double-buffering allows lock-free readers. Mutations create local structural entropy; local repair prevents entropy propagation. This RFC is the normative specification for RB-CSR with an implementation plan delivered in phases.

---

# Part I — Normative Specification

## 1. Core Thesis

> **Reads must never inherit unbounded historical fragmentation.**

RB-CSR achieves this through three mechanisms:

1. **Fixed-size blocks with occupancy masks.** Each node's adjacency is stored in blocks of fixed capacity (64 edges per block). A 64-bit mask tracks which slots are live. Each non-tail block MUST maintain a minimum of 48 live edges (75% occupancy), yielding worst-case scan amplification of 1.33×.

2. **Edges sorted by destination within each block.** Binary-search lookup of specific edges, O(log 64) per block. Full adjacency intersection may use block-wise probing, temporary materialization, or hash-based sets — global merge-join is not guaranteed in RFC-0001.

3. **Local repair only.** When mutations degrade occupancy below threshold, repair is performed only on the affected node, never on the full graph.

---

## 2. Core Structures

### 2.1 NodeId

```zig
pub const NodeId = struct { index: u32 };
```

Flat index, opaque to the consumer. Internally resolved to (page, slot) for page-based pool growth.

### 2.2 Edge

```zig
pub const Edge = packed struct {
    destination: u32,
    relation: u16,
    flags: EdgeFlags,
};

pub const EdgeFlags = packed struct(u16) {
    _unused: u16 = 0,  // reserved; future: pinned, hidden, traversed
};
```

8 bytes total. `relation` labels the edge type (friend, works_at, etc.). `flags` are application-defined boolean bits. Larger properties (weights, timestamps) are stored in external columnar arrays keyed by `(source, destination)` (deferred to a later phase).

### 2.3 NodeFlags

```zig
pub const NodeFlags = packed struct(u32) {
    needs_repair_fwd: bool,
    needs_repair_rev: bool,
    removed: bool,
    _reserved: u29 = 0,
};
```

Backed by `u32` so that `NodeAdj` measures 28 bytes (multiple of 4), keeping all `u32` fields naturally aligned.

### 2.4 NodeAdj — per-node adjacency descriptor

```zig
pub const NodeAdj = extern struct {
    first_block_fwd: u32,
    block_count_fwd: u16,
    group_count_fwd: u16,
    first_group_fwd: u32,

    first_block_rev: u32,
    block_count_rev: u16,
    group_count_rev: u16,
    first_group_rev: u32,

    flags: NodeFlags,
};
```

`group_count_* == 0` is the fast path: blocks are contiguous. `group_count_* > 0` means the node's blocks are reachable via a `BlockGroup` chain.

### 2.5 NodeBuffer — per-node RCU double-buffer

```zig
pub const PublishedMeta = packed struct(u64) {
    fwd_index: u1 = 0,
    rev_index: u1 = 0,
    needs_repair_fwd: bool = false,
    needs_repair_rev: bool = false,
    removed: bool = false,
    _reserved: u59 = 0,
};

pub const SideAdj = extern struct {
    first_block: u32,
    block_count: u16,
    group_count: u16,
    first_group: u32,
};

pub const NodeBuffer = extern struct {
    published_meta: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(PublishedMeta{})),
    fwd_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    rev_claim: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    fwd_buffers: [2]SideAdj,
    rev_buffers: [2]SideAdj,
    degree_fwd: u16 = 0,
    degree_rev: u16 = 0,
};
```

`degree_fwd` / `degree_rev` cache the live edge count for each side.
The sentinel value `0xFFFF` signals overflow. Phase 1 query APIs MAY
conservatively fall back to an O(B) scan to guarantee exact answers
under concurrent mutation; the cache saturates to overflow on edge
addition and, when a mutation or repair drops the count below the
overflow threshold, recovers an exact value so it remains a tight
heuristic rather than a permanent unknown.
It reuses what was previously a 4‑byte cache-line padding field,
keeping `NodeBuffer` at exactly 64 bytes.
Writers stage side-local updates in the inactive `fwd_buffers[]` /
`rev_buffers[]` entries, then publish a new coherent node snapshot by
CAS/updating `published_meta` with `.release`.
Readers load `published_meta` with `.acquire`, decode both published side
indices plus `removed` / `needs_repair_*`, and therefore always observe a
complete `NodeAdj` snapshot — old or new, never a partial node update.
`fwd_claim` and `rev_claim` are per-node non-blocking writer exclusion bits.

**Copy-on-write rule:** Active blocks MUST NOT be mutated in-place
while lock-free readers exist. When a mutation changes block
contents, affected blocks MUST be copied to newly allocated
private blocks. The mutated `NodeAdj` is updated to point to the
new blocks. Old blocks become **retired** — reachable by active
readers, never written to again.

A reader MUST copy the published `NodeAdj` by value into the iterator
or read context before traversal begins. Iterators MUST NOT retain a
pointer to the published side buffers. The per-side RCU double-buffers
have only two slots each; holding a pointer allows a subsequent writer
recycle to overwrite the reader's view.

### 2.6 EdgeBlockFwd — forward edge block

```zig
pub const EdgeBlockFwd = struct {
    mask: u64,
    edges: [64]Edge,  // sorted by destination
};
```

520 bytes. 64 outgoing edges. **Dense storage:** live entries occupy slots `[0, live_count)`
with no internal holes. `mask` is `denseMask(live_count)` where:
- `live_count == 0`  → `mask = 0`
- `live_count == 64` → `mask = 0xFFFF_FFFF_FFFF_FFFF`
- otherwise          → `mask = (1 << live_count) - 1`

- **addEdge:** binary-search insertion point, `memmove` right, write, `live_count++`,
  recompute `mask = denseMask(live_count)`.
- **removeEdge:** binary-search, `memmove` left to compact, `live_count--`, recompute mask.
- **Iteration:** `@ctz(mask)` + `mask &= mask - 1` — identical to sparse, zero branches.
- **Point lookup:** binary-search `edges[0..live_count)`. For multi-block nodes,
  compare `edges[0].destination` and `edges[live_count-1].destination` against the target to skip
  irrelevant blocks with per-block O(1) range rejection — the sorted invariant makes range filtering exact.

### 2.7 EdgeBlockRev — reverse edge block

```zig
pub const EdgeBlockRev = struct {
    mask: u64,
    sources: [64]u32,  // sorted by source
};
```

264 bytes. 64 incoming source node IDs. Same dense storage model as `EdgeBlockFwd`.
Half the size because reverse adjacency only stores the source `u32`, not `relation`
or `flags`. Full edge metadata can be retrieved by binary-searching the source node's
forward block.

### 2.8 EdgeBlockGroup — contiguous block span

```zig
pub const EdgeBlockGroup = struct {
    start: u32,
    next: u32,  // 0xFFFF_FFFF = end of chain
    count: u16,
    _pad: u16 = 0,
};
```

A chainable span of physically contiguous blocks. Forward and reverse adjacency share the same `EdgeBlockGroup` pool. 12 bytes aligned — avoids cache-line splits during chain traversal.

### 2.9 Page-based pools

All pools grow via **pages** — never by `realloc` of existing data. Pages are allocated via the user-supplied allocator and never moved.

| Pool | Entries per page | Page size | Purpose |
|------|:---:|:---:|---|
| NodeBuffer | 256 | ~15 KB | Per-node RCU descriptors |
| EdgeBlockFwd | 64 | ~33 KB | Outgoing edge blocks |
| EdgeBlockRev | 64 | ~17 KB | Incoming edge blocks |
| EdgeBlockGroup | 128 | 1536 B | Shared block group pool |
| BlockMeta (blocks) | 64 | ~12 B/entry | Lock-free retired/free stack metadata per block |
| BlockMeta (groups) | 128 | ~12 B/entry | Lock-free retired/free stack metadata per group |

Page sizes are chosen to fit within common L1/L2 cache sizes, maximizing locality during traversal.

Groups are reused via lock-free free/retired stacks with epoch-based
reclamation — the same mechanism as edge blocks.  `BlockMeta` (shared
between blocks and groups) stores a `next` pointer and `epoch` tag
out-of-line so that retiring a published group never mutates memory
an active reader may still traverse.

---

## 3. Fundamental Invariants

### 3.1 Read Amplification Bound

```
scan_slots(u) ≤ degree(u) × 1.33  (for non-tail blocks)
```

Minimum block occupancy: 48/64 (75%). Maximum slots scanned per live edge: 1.33×. The tail block (last block of a node) is exempt from the occupancy minimum.

### 3.2 Run Fragmentation Bound

Every run (contiguous span of blocks described by a `BlockGroup`) except the tail run SHOULD contain at least 4 blocks. A node MAY accumulate up to 4 runs before repair becomes required.

Runs below this bound are treated as **repair debt**, not immediate structural corruption: after a public API call returns, such a node MUST have the corresponding `needs_repair_*` flag set. A grouped adjacency that is physically contiguous is also repair debt and MUST be marked the same way until canonicalized back to `group_count == 0`.

### 3.3 Forward/Reverse Consistency

After every public API call returns, every live forward edge `(n → dst)` MUST have a corresponding live reverse entry `(dst ← n)`, and vice versa.

### 3.4 Edge Ordering

Edges within each block MUST be sorted by `destination` (forward) or source (reverse). The sorted invariant is per-block, not global across blocks or runs.

### 3.5 Dense Mask Invariant

Every `EdgeBlockFwd` and `EdgeBlockRev` stores edges in **dense** layout: live entries occupy slots `[0, live_count)` with no internal holes. `mask` MUST equal `denseMask(live_count)` (see §2.6). This allows both O(log 64) binary-search lookup and O(live_count) zero-branch iteration via `@ctz`.

### 3.6 Repair Debt Bounds

`needs_repair` MAY indicate too many groups, excessive tail slack,
a grouped-but-contiguous canonicalization opportunity, a run
fragmentation bound violation, or another compaction opportunity.
Non-tail blocks MUST never drop below 48 live entries after any public API call returns. If a mutation
would cause a non-tail block to drop below 48, it MUST either repair
synchronously within the same call or return `error.RepairRequired`.

---

## 4. Public API

### 4.1 Types

```zig
pub const NodeId = struct { index: u32 };
pub const EdgeFlags = packed struct(u16) { _unused: u16 = 0; };
pub const NodeFlags = packed struct(u32) {
    needs_repair_fwd: bool, needs_repair_rev: bool,
    removed: bool, _reserved: u29 = 0;
};
pub const Edge = packed struct { dst: u32, relation: u16, flags: EdgeFlags };
pub const Violation = union(enum) { ... };  // see §7
```

### 4.2 Error Set

```zig
pub const GraphError = error{
    OutOfMemory,
    InvalidNode,           // NodeId out of bounds, removed, or tombstoned
    EdgeAlreadyExists,     // duplicate in non-multigraph mode
    CorruptGraph,          // validate() found invariant violation
    ConcurrentMutation,    // reserved: per-node writer contention
    UnsupportedOperation,  // feature not yet in current phase
    RepairRequired,        // hard read bound would be violated
};
```

| Error | May be returned by | Meaning |
|-------|-------------------|---------|
| `OutOfMemory` | `init`, `addNode`, `addEdge`, `repairNode`, `repairBudgeted`, `debugValidate` | Allocator exhausted. Graph unchanged. |
| `InvalidNode` | All queries taking `NodeId`, `addEdge`, `removeEdge`, `removeNode` | `id.index >= node_count`, or node is removed/tombstoned. |
| `EdgeAlreadyExists` | `addEdge` | Duplicate edge in non-multigraph mode. |
| `CorruptGraph` | `validate` | Structural invariant violated. |
| `ConcurrentMutation` | Reserved | Future: writer contention detected. |
| `UnsupportedOperation` | multigraph ops (Phase 3) | Feature not yet in current phase. |
| `RepairRequired` | `addEdge`, `removeEdge` (if sync repair disabled) | Hard amplification bound would be violated. Call `repairNode` or `repairBudgeted`. |

`removeEdge` returns `bool`: `true` if the edge was found and removed, `false` if it did not exist. It does NOT return `error.EdgeNotFound`.

### 4.3 Core Functions

```zig
pub fn init(allocator: Allocator) GraphError!Graph;
pub fn deinit(self: *Graph) void;

pub fn addNode(self: *Graph) GraphError!NodeId;
pub fn removeNode(self: *Graph, node: NodeId) GraphError!void;          // Phase 2
pub fn addEdge(self: *Graph, from: NodeId, to: NodeId, relation: u16, flags: u16) GraphError!void;
pub fn removeEdge(self: *Graph, from: NodeId, to: NodeId) GraphError!bool;

pub fn neighbors(self: *const Graph, node: NodeId) GraphError!NeighborIterator;
pub fn inNeighbors(self: *const Graph, node: NodeId) GraphError!NeighborIterator;
pub fn outDegree(self: *const Graph, node: NodeId) GraphError!usize;
pub fn inDegree(self: *const Graph, node: NodeId) GraphError!usize;
pub fn nodeCount(self: *const Graph) usize;
pub fn edgeCount(self: *const Graph) u64;
pub fn hasNode(self: *const Graph, id: NodeId) bool;

pub fn repairNode(self: *Graph, node: NodeId) GraphError!void;
pub fn repairBudgeted(self: *Graph, max_nodes: usize) GraphError!usize;
pub fn validate(self: *const Graph) GraphError!void;
pub fn debugValidate(self: *const Graph, allocator: Allocator) GraphError![]Violation;
```

### 4.4 NeighborIterator

```zig
pub const NeighborIterator = struct {
    pub fn next(self: *NeighborIterator) ?NodeId;
    /// MUST be called to signal reader completion. Decrements
    /// `active_readers`, enabling retired block reclamation.
    pub fn deinit(self: *NeighborIterator) void;
    pub fn materialize(self: *NeighborIterator, allocator: Allocator) ![]NodeId;
};
```

Streaming, zero-allocation iteration via `@ctz(mask)` + `mask &= mask - 1`. `materialize` allocates a contiguous slice for algorithms that need random access (cycle detection).

### 4.5 GraphBuilder

```zig
pub const GraphBuilder = struct {
    pub fn init(allocator: Allocator) GraphError!GraphBuilder;
    pub fn deinit(self: *GraphBuilder) void;
    pub fn addNode(self: *GraphBuilder) GraphError!NodeId;
    pub fn addEdge(self: *GraphBuilder, from: NodeId, to: NodeId, relation: u16, flags: u16) GraphError!void;
    pub fn freeze(self: *GraphBuilder) GraphError!Graph;
};
```

`freeze()` produces a `Graph` with compact initial layout, zero repair debt, and edges pre-sorted within each block. The resulting graph is a normal mutable `Graph`.

### 4.6 API Guarantees

| Function | Mutates | May repair | Blocks readers |
|----------|:-------:|:----------:|:--------------:|
| `neighbors`, `inNeighbors` | No | No | **No** |
| `outDegree`, `inDegree` | No | No | **No** |
| `nodeCount`, `edgeCount`, `hasNode` | No | No | **No** |
| `validate`, `debugValidate` | No | No | **No** |
| `addNode` | Yes | No | **No** |
| `addEdge` | Yes | Maybe | **No** |
| `removeEdge` | Yes | No | **No** |
| `removeNode` | Yes | Yes | **No** |
| `repairNode`, `repairBudgeted` | Yes | Yes | **No** |

Readers are lock-free via per-node RCU. Concurrent writes are safe
only when their touched adjacency endpoints are disjoint (see §5.3).

---

## 5. Concurrency Model

### 5.1 Per-node RCU

Each node has a `NodeBuffer` with per-side double-buffers (`fwd_buffers[]`,
`rev_buffers[]`) and a single atomic `published_meta` word that selects the
published side indices and carries the public node flags. Readers load
`published_meta` with `.acquire` and read without locks. Writers stage updates
in inactive side buffers, then publish a new coherent node snapshot by CAS / a
single `.release` update of `published_meta`.

The graph maintains a global `epoch` counter (`std.atomic.Value(u64)`),
a diagnostic `active_readers` count (`std.atomic.Value(u32)`), and a bounded
set of atomic reader epoch slots for retired block reclamation (see §5.4).

`edge_count` is a `std.atomic.Value(u64)` so that lock-free readers may call
`edgeCount()` without external synchronization.

### 5.1a Copy-on-Write Granularity

Mutations MAY copy only the affected block. If replacing a block
breaks physical contiguity, the inactive NodeAdj MUST represent the
new logical adjacency by splitting the original BlockGroup into
prefix / private / suffix groups.

If a COW split would cause `group_count` to exceed the node's
maximum allowed groups (see §3.2), the mutation MUST either repair
synchronously or return `error.RepairRequired`. Repair merges
adjacent groups back below the threshold before the mutation
proceeds.

Unchanged published blocks MAY be referenced by both old and new
NodeAdj versions because published blocks are immutable under RCU.

A block is retired only when it is no longer reachable from any
active or inactive NodeAdj slot that may be observed by readers.

### 5.2 Forward/Reverse Atomicity

`addEdge` and `removeEdge` affect two nodes (`from` and `to`). To avoid inconsistency after a public API call returns, the implementation MUST:

1. Validate `from` and `to` exist.
2. Pre-allocate any new blocks/groups needed for both forward and reverse.
3. Check for duplicate edges BEFORE modifying any published state.
4. Prepare forward and reverse RCU copies in private.
5. Publish the **reverse** endpoint first (`.release` flip on `to`).
6. Publish the **forward** endpoint second (`.release` flip on `from`).
7. Update `edge_count` only after both directions are published.

Publishing reverse first ensures that once the new forward edge is
visible, the corresponding reverse entry is already visible. A reader
that observes the new reverse entry before the forward edge may still
observe a transient mixed version, which is allowed by the concurrency
contract.

For self-edges where `from == to`, the mutation claims both logical
adjacencies on the node, prepares both forward and reverse changes in the
inactive side buffers, and publishes them with a single atomic
`published_meta` update.

No partial publish is allowed from the perspective of a completed public
API call. During a concurrent two-node mutation, readers may observe a
transient mixed version across the two endpoints. Per-node RCU guarantees
structural validity per adjacency, not global snapshot atomicity.

If reverse preparation fails (e.g., `OutOfMemory`), the forward changes
MUST be discarded before publication.

The sequencing of flips MAY leave a brief implementation-dependent
window where one endpoint observes the new version and the other
still observes the old version. After both flips complete, consistency
is restored. Callers requiring global snapshot consistency must
externally serialize graph-wide reads and writes.

### 5.3 Writer Exclusion

Concurrent writers are safe only if their touched logical adjacencies
are disjoint. `addEdge(from, to)` touches `forward(from)` and
`reverse(to)`. `removeEdge(from, to)` touches the same two logical
adjacencies.

The implementation MUST protect each touched logical adjacency with a
non-blocking writer claim. If any required claim is already held, the mutation
MUST fail without waiting, returning `error.ConcurrentMutation`, and MUST
release any claim it acquired before failing.

A claim is not a reader lock and MUST NOT block readers. It only prevents two
writers from concurrently mutating the same inactive `NodeAdj` slot or the same
logical adjacency metadata.

### 5.4 Retired Block Reclamation

Blocks retired during copy-on-write mutations are reclaimed via per-reader
epoch tracking and lock-free retired/free stacks:

1. **Readers** snapshot the global `epoch` on entry and publish that epoch in
   an atomic reader slot before traversing block memory. On exit, they clear the
   slot. `active_readers` MAY be maintained as a diagnostic counter, but it is
   not the reclamation predicate.

   Any public function that traverses block memory MUST enter a reader
   critical section: `neighbors`, `inNeighbors`, `outDegree`, `inDegree`,
   `validate`, `debugValidate`, and any internal traversal used by
   algorithms. Iterator-based APIs expose `deinit()` for the exit;
   non-iterator APIs enter and exit internally without caller participation.

   If no reader slot is available, the reader MUST enter an overflow state that
   conservatively prevents reclamation until that reader exits.

2. **Writers** tag every retired block with the current epoch and push it to a
   lock-free retired stack/queue. Writers bump the global `epoch` counter after
   publishing. Any reader starting after the bump will see the new version and
   never reference the retired block.

3. **Reclamation** runs opportunistically at the end of write operations or via
   an explicit budgeted reclaim call. Let `safe_epoch` be the minimum epoch
   published by any active reader. If there are no active readers,
   `safe_epoch = current_epoch + 1`. If any reader is in overflow, no block is
   reclaimable.

   A retired block tagged with epoch `E` is safe to move to the free list when
   `E < safe_epoch`.

4. **Reuse** is allowed only from the lock-free free list. A block MUST NOT be
   returned to the free list until the reclamation predicate above holds.

This guarantees that no block is freed while any reader might still reference
it, while allowing reclamation to continue under continuous reader traffic once
all readers that could have observed a retired block have exited.

---

## 6. Mutation Model

### 6.1 addEdge

```
1. Validate `from` and `to` exist.
2. Acquire NodeBuffer for `from` and `to`.
3. Pre-allocate any needed blocks/groups for forward and reverse.
4. Check for duplicate edge (binary-search in forward blocks of `from`).
5. Copy affected forward/reverse blocks into private copies.
   Copy NodeAdj → inactive RCU slots for both nodes.
   Update inactive NodeAdj to point to the private block copies.
6. Forward insert: binary-search insertion point, `memmove` right,
   write Edge at slot, increment `live_count`, recompute `mask = denseMask(live_count)`.
7. Reverse insert: same procedure on reverse block.
8. Publish **reverse** first: flip(.release) for `to` (inNeighbors now consistent).
9. Publish **forward**: flip(.release) for `from`.
10. edge_count += 1.
```

### 6.2 removeEdge

```
1. Validate `from` and `to` exist.
2. Acquire NodeBuffer for `from` and `to`.
3. Binary-search for `dst` in forward blocks of `from`.
   If not found → return false (no publish).
4. Binary-search for `from` in reverse blocks of `to`.
   If the forward edge exists but the reverse entry is missing,
   discard private state and return `error.CorruptGraph`.
5. Copy affected forward/reverse blocks into private copies.
   Copy NodeAdj → inactive RCU slots for both nodes.
   Update inactive NodeAdj to point to the private block copies.
6. `memmove` left to compact sorted arrays, decrement `live_count`,
   recompute `mask = denseMask(live_count)`.
7. If a non-tail block would fall below 48 live entries:
     synchronously repair before publishing, OR
     return `error.RepairRequired` without publishing.
   If the affected block is the tail block:
     mark `needs_repair` if tail slack exceeds policy.
8. Publish **reverse** first: flip(.release) for `to`.
9. Publish **forward**: flip(.release) for `from`.
10. edge_count -= 1.
11. Return true.
```

### 6.3 removeNode

Implemented in Phase 2.

Strategy: tombstone nodes.
  1. Mark A as `NodeFlags.removed = true`.
  2. For every outgoing edge A → X:
       remove from `forward(A)` AND remove reverse entry X ← A.
  3. Incoming edges Y → A may persist as tombstoned references until compaction.
  4. Traversal (`neighbors`, `inNeighbors`) skips removed destination nodes.
  5. Repair/compaction may later remove tombstoned incoming references.

Tombstoned incoming references may therefore persist **structurally** in
stored adjacency blocks until repair, but they are no longer part of the
public **logical** graph. Public traversal, public degree queries, and
`edge_count` MUST exclude such tombstoned references even before
compaction runs.

Full scan removal (O(E)) is available as a compaction step in repair, not on every `removeNode` call.

### 6.4 Local Repair

Repair now uses a **single-pass rebuild**: all live edges are read in
sorted order from the existing blocks, packed into new densely-filled
blocks, and the new adjacency is published once. This is O(B) instead
of the earlier O(B²) pair-merge approach.

`repairNode(node)` performs the rebuild for both sides.

`repairBudgeted(max_nodes)` repairs at most `max_nodes` distinct live
nodes before returning. Stale queue entries, removed nodes, and no-op
candidates discovered during scanning do **not** consume the budget.
Each repaired node incurs a **full rebuild** of the affected adjacency
side (forward or reverse), so a single serviced node costs O(B). This
is the intended trade-off: the budget controls how many nodes are
actually repaired per call, not how many block pairs are merged or how
many stale debt entries are inspected, since a partial repair of a
fragmented adjacency would leave it in an inconsistent state.

Repair MUST follow publish-after-build semantics: build repaired
blocks privately, validate, then publish updated `NodeAdj` via RCU
flip. Repair clears `needs_repair_*` only after the rebuilt layout
again satisfies the run fragmentation and canonical representation
rules for that side.

### 6.5 Multigraph Mode

Implemented in Phase 3.

When enabled via a configuration flag (default: disabled), multiple edges with the same `(from, to)` pair are allowed. Edge identity requires an `EdgeId`. `addEdge` no longer checks for duplicates. `removeEdge` requires an `EdgeId` or removes all edges matching `(from, to)`.

---

## 7. Validation Contract

### 7.1 Violation Type

```zig
pub const Violation = union(enum) {
    degree_mismatch:              struct { node: u32, expected: u32, actual: u32 },
    occupancy_below_threshold:    struct { node: u32, block: u32, occupancy: u32 },
    mask_bit_out_of_range:        struct { node: u32, block: u32 },
    invalid_dst:                  struct { node: u32, block: u32, slot: u32, dst: u32 },
    forward_reverse_mismatch:     struct { node: u32, dst: u32 },
    unsorted_block:               struct { node: u32, block: u32, slot: u32 },
    blockgroup_chain_cycle:       struct { node: u32, group: u32 },
    blockgroup_overlap:           struct { node: u32, group_a: u32, group_b: u32 },
    run_fragmentation_requires_repair: struct { node: u32, group: u32, count: u16 },
    grouped_layout_needs_canonicalization: struct { node: u32, first_group: u32 },
    block_double_owned:           struct { block: u32 },
    block_orphaned_in_free_list:  struct { block: u32 },
    repair_debt_invalid_node:     struct { entry: u32 },
    edge_count_mismatch:          struct { expected: u64, actual: u64 },
    retired_block_reachable:      struct { block: u32, node: u32 },
};
```

### 7.2 Checks

**Per-node:**
- `outDegree` equals the public logical forward degree (visible non-tombstoned outgoing refs)
- `inDegree` equals the public logical reverse degree (visible non-tombstoned incoming refs)
- Forward/reverse edges are consistent (bijection)
- Edges within each block are sorted
- `group_count == 0` iff blocks are truly contiguous
- `group_count > 0` iff blocks are reachable via the group chain with no cycles

**Per-block:**
- `mask == denseMask(@popCount(mask))` (dense invariant: no internal holes)
- `mask` has no bits set beyond capacity (bit 63 max)
- Live count equals `@popCount(mask)`
- Occupied slots contain valid `dst` nodes
- Non-tail block occupancy ≥ 48 (75%) always. Tail block exempt.
  Tiny-degree single-block node exempt. `needs_repair` is NOT an
  exemption for non-tail occupancy.

**Per-group:**
- Chain has no cycles
- Groups do not overlap
- Run fragmentation bound respected unless node is marked `needs_repair`
- Grouped layouts that are physically contiguous MUST be marked `needs_repair` until canonicalized back to `group_count == 0`

**Global:**
- `edge_count` equals the sum of public logical forward degrees (which equals the sum of public logical reverse degrees)
- Tombstoned references to or from removed nodes are excluded from those public logical counts even if they still persist structurally until compaction
- Free blocks are not owned by nodes
- Owned blocks are not in free lists
- Retired blocks MUST NOT be reachable from any current active NodeAdj.
  Blocks reachable only from reader-held snapshots may remain retired
  until reclamation. Reclamation safety is verified by epoch/
  active_readers invariants, not by validation.
- Repair debt queues are best-effort auxiliary structures.  They MAY contain
  stale or removed entries.  The authoritative source of repair debt is
  `needs_repair_*` flags on published node state.

### 7.3 API

```zig
pub fn validate(self: *const Graph) GraphError!void;
// Fast path: returns error.CorruptGraph on first violation. Does not allocate.
// Guarantees full global validation only when no mutations are running.
// If called concurrently with mutations, may observe transient
// forward/reverse mismatch and spuriously return error.CorruptGraph.
// Callers must externally serialize validation against writers for
// reliable results.

pub fn debugValidate(self: *const Graph, allocator: Allocator) GraphError![]Violation;
// Allocates and returns every violation. For debugging and testing.
```

---

## 8. Persistence Model (non-normative)

This section describes the intended on-disk format for a future implementation phase. It is informational, not part of Phase 1 delivery.

The format is mmap-friendly: flat arrays of structs with fixed-size pages, little-endian, pointer-free (offsets instead of pointers).

```zig
const FileHeader = packed struct {
    magic: u64,
    version_major: u16,
    version_minor: u16,
    node_count: u64,
    edge_count: u64,
    compression_type: u8,
    _reserved: [7]u8,
    checksum: u64,
};
```

Pages follow the header in order: NodeBuffer pages, EdgeBlockFwd pages, EdgeBlockRev pages, BlockGroup pages. Free lists and repair queues are reconstructed at load time.

---

# Part II — Implementation Phases

## Phase 1: Core Mutable Graph (Minimum Shippable)

**Goal:** Directed graph with add/remove edges, lock-free readers, local repair, and validation.

**Deliverables:**
- `init` / `deinit` with page-based pool growth
- `addNode`, `hasNode`, `nodeCount`, `edgeCount`
- `addEdge` with forward/reverse atomicity (§5.2) and sorted-edge binary-search insert
- `addEdge` duplicate-edge fail-fast (binary-search check before publish)
- `removeEdge` returns `bool`: `true` if removed, `false` if edge did not exist
- `neighbors` / `inNeighbors` via `NeighborIterator`
- `outDegree` / `inDegree` via `@popCount` (with RCU reader guard)
- `repairNode` (block pack) and `repairBudgeted`
- `validate` / `debugValidate`
- Per-node RCU (`NodeBuffer` double-buffer, no global locks)
- `GraphBuilder` for bulk loading

**Acceptance criteria:**
- BFS, DFS, and cycle detection algorithms pass unchanged
- `validate()` reports no violations after every mutation
- `outDegree`/`inDegree` always consistent with `neighbors().materialize().len`
- Forward/reverse always consistent after every public API call
- Occupancy thresholds enforced: non-tail blocks never remain below 48/64 after any public API call; tail slack and group fragmentation may trigger `needs_repair`
- `repairBudgeted` reduces repair debt
- Concurrent readers on different nodes never block

**NOT implemented in Phase 1:**
- Multigraph mode (returns `error.UnsupportedOperation`)
- Persistence / mmap
- Other block sizes (16, 32, 128)
- Per-block compression
- External property arrays

---

## Phase 2: Node Deletion

**Goal:** Remove nodes with tombstone semantics.

**Deliverables:**
- `removeNode` marks node as `removed`, clears outgoing adjacency
- `neighbors` / `inNeighbors` skip edges to removed nodes
- Forward tombstone debt is flagged immediately on live predecessors: after
  `removeNode(A)`, any live node B that held an edge B → A has
  `needs_repair_fwd` set so that `repairBudgeted` discovers the
  compaction work without a full-graph scan.
- Repair compaction: full-scan removal of incoming edges to tombstoned nodes (triggered by `repairNode`)

**Acceptance criteria:**
- After `removeNode(A)`:
  - A is marked removed.
  - All outgoing edges A → X are removed from `forward(A)` and `reverse(X)`.
  - `neighbors(B)` no longer includes A if A → B existed.
  - Incoming edges Y → A may remain as tombstoned references until compaction.
  - Those tombstoned references are not part of the public logical graph: public traversal, public degree queries, and `edge_count` exclude them immediately after `removeNode(A)`.
- After compaction repair, all traces of removed nodes are eliminated.

---

## Phase 3: Multigraph Mode

**Goal:** Allow multiple edges between the same node pair.

**Deliverables:**
- Configuration flag enabling multigraph mode
- `EdgeId` type for edge disambiguation
- `addEdge` skips duplicate check in multigraph mode
- `removeEdge` accepts optional `EdgeId`

**Acceptance criteria:**
- Two calls to `addEdge(A, B, 1, 0)` with multigraph enabled succeed
- `neighbors(A)` returns B twice
- `removeEdge` with `EdgeId` removes the correct edge

---

## Phase 4: Persistence (mmap)

**Goal:** Read/write graphs to disk with instant startup.

**Deliverables:**
- Write graph to mmap-compatible file format
- Read graph from file with zero-copy where possible
- Versioned header with checksum validation

---

## Phase 5: Concurrent Writer Support

**Goal:** Safe concurrent writes via per-node non-blocking claims.

**Deliverables:**
- `NodeBuffer` holds per-node `fwd_claim` / `rev_claim` atomic bits
- `addEdge` and `removeEdge` acquire claims before mutation; fail with `ConcurrentMutation` if either claim is held
- Mutations bump `active_writers` counter; debug/legacy lists disabled when concurrent writers detected
- `repairNode`/`repairBudgeted` also acquire per-node claims
- Reclamation deferred until after writer guard ends

---

## Phase 6: Compression & Extended Block Sizes

**Goal:** Per-block compression and alternative block sizes for memory-constrained or SIMD-optimized deployments.

**Deliverables:**
- Tagged union `Block64` with `uncompressed`, `delta_u16` variants
- Accessor functions dispatch internally on block type
- Block16, Block32, Block128 page sizes

---

## Phase 7: External Property Arrays

**Goal:** Columnar storage for edge weights, timestamps, and node properties.

**Deliverables:**
- Property arrays keyed by `(source, destination)` pair
- Stable indices across repair operations
- Bulk property load/store APIs

---

# Part III — Benchmarking

## 9. Benchmarking Goals

### 9.1 Correctness Benchmarks

- `validate()` reports zero violations after 100K random insertions and deletions.
- Forward/reverse consistency maintained after every mutation.
- `outDegree`/`inDegree` consistent with iteration count.

### 9.2 Scan Amplification Verification

- Measured `scan_slots / live_edges` MUST NOT exceed 1.33× across any node's non-tail blocks.
- Benchmark: 1M edges, 50% random deletion attempts with synchronous repair
disabled. Mutations either preserve the hard non-tail bound or return
`RepairRequired`.
- Benchmark: 1M edges, 50% deletions, repair after each batch of 10K → confirm 1.33× bound.

### 9.3 Mutation Throughput

- `addEdge` throughput on a graph with 10K nodes, 100K edges.
- `removeEdge` throughput.
- Repair throughput: block packs per second, blocks reclaimed per `repairBudgeted` step.

### 9.4 Reader Latency Under Repair

- Reader thread executing BFS on 10K nodes while writer thread performs `repairBudgeted`.
- Reader latency distribution (p50, p99, p999) MUST NOT degrade beyond 2× baseline when writer is active, demonstrating RCU isolation.

### 9.5 Memory Overhead

- Measure total bytes allocated vs theoretical minimum (edges × 8 + nodes × 28).
- Confirm overhead is within expected range (~1.5× including reverse index and empty slots).

---

# Part IV — Appendices

## A. Resolved Inconsistencies

1. **v0/post-v0 framing removed.** All features are specified and assigned to implementation phases. No "deferred to post-v0" language remains.

2. **NodeId unified.** Public API uses `struct { index: u32 }`. Internal page/slot resolution is opaque.

3. **Group naming unified.** `BlockRun` renamed to `BlockGroup` throughout. Forward and reverse share a single pool.

4. **Occupancy threshold uniform.** 75% minimum (48/64, 1.33×) for all block sizes. No per-profile variation.

5. **Edge ordering specified.** Edges sorted by `destination` within each block. Binary-search lookup per block. Global merge-join is not guaranteed.

6. **Forward/reverse atomicity specified.** Both directions prepared privately, published together. No partial publish from completed call perspective. Transient mixed version possible during concurrent mutation.

7. **Writer exclusion clarified.** Safe only when touched adjacencies (forward of from, reverse of to) are disjoint, not just different node IDs.

8. **Repair debt hard bound specified.** Mutations that would violate 1.33× bound must repair or return `error.RepairRequired`.

9. **removeNode assigned to Phase 2.** Tombstone semantics with optional full-scan compaction during repair.

10. **Multigraph assigned to Phase 3.** Requires `EdgeId` for disambiguation.

11. **Persistence described as non-normative section.** Assigned to Phase 4.

12. **GraphConfig eliminated.** `init(allocator)` — no capacity parameters. Bounded memory via `FixedBufferAllocator`.

13. **Degree not stored.** Computed from `@popCount(mask)`. Eliminates desynchronization bug surface.

14. **EdgeMeta eliminated.** `relation` and `flags` are direct fields of `Edge`. Zig-style flat struct, no nested metadata wrapper.

15. **Dense occupancy model adopted.** Live entries occupy `[0, live_count)` with no internal holes. `mask = denseMask(live_count)`. Binary-search works correctly, iteration via `@ctz` is preserved.

16. **RCU copy-on-write specified.** Blocks are never mutated in-place while lock-free readers exist. Mutations copy affected blocks to private copies, publish updated `NodeAdj`, and retire old blocks.

17. **Retired blocks separated from free blocks.** Phase 1 uses lightweight global quiescent-state reclamation. Free lists contain only blocks proven unreachable.

18. **Writer exclusion corrected.** Safe only when touched adjacencies (forward of from, reverse of to) are disjoint, not just different node IDs.

19. **Global merge-join claim removed.** Intersection uses block-wise probing, materialization, or hashing — not global merge-join.

20. **Error set cleaned.** `NodeNotFound`, `EdgeNotFound`, `InvalidEdge` removed. `InvalidNode` is the single node-error. `removeEdge` returns `bool`, not `EdgeNotFound`.

21. **Query API returns errors.** `neighbors`, `inNeighbors`, `outDegree`, `inDegree` now return `GraphError!T`.

22. **BlockGroup page size corrected.** 12 bytes aligned (`_pad: u16` added). 128 entries = 1536 B per page.

23. **Repair debt hard bound strengthened.** Non-tail blocks MUST never drop below 48 after any public call. `needs_repair` = groups/slack/compaction, not underfull blocks.

24. **Benchmark deletion scenario corrected.** Tests with sync repair disabled expect either bound preservation or `RepairRequired`.

25. **removeNode Phase 2 clarified.** Outgoing edges removed from both forward and reverse. Incoming edges may persist until compaction.

26. **Forward tombstone debt published immediately.** `removeNode` sets `needs_repair_fwd` on every live predecessor that held an edge to the removed node, so budgeted repair discovers the work without a full scan.

27. **Repair debt queues are best-effort.** `repair_fwd` and `repair_rev` MAY contain stale or removed entries. Validation does not treat in-range entries as corruption.  The authoritative source of debt is `needs_repair_*` flags.

28. **Degree cache overflow recovery.** When a deletion or repair drops the visible edge count below the overflow threshold (65535), the degree cache recovers an exact value rather than remaining at the `0xFFFF` sentinel indefinitely.

---

## B. References

- [DESIGN.md](./DESIGN.md) — Master design specification.
- [CSR format](https://en.wikipedia.org/wiki/Sparse_matrix#Compressed_sparse_row_(CSR,_CRS_or_Yale_format))
- [PMA / PCSR](https://en.wikipedia.org/wiki/Packed_memory_array)
- [SQLite architecture](https://www.sqlite.org/arch.html)
- [DuckDB](https://duckdb.org/)
