# azigmuth

A directed graph storage library for Zig based on the RB-CSR design in `RFC.md`.

- page-based node and edge-block pools
- forward and reverse adjacency
- lock-free reader iterators via per-node RCU snapshots
- sorted fixed-size struct-of-arrays edge blocks (dense, cache-line aligned)
- local repair and validation
- tombstone-based node deletion (Phase 2) with debt/repair cleanup
- stable per-edge property rows + caller-owned columnar stores (Phase 7)
- a `GraphBuilder` bulk-construction handle

## Design limits

Capacity ceilings derive from the comptime **storage profile** (RFC §2.9.1);
page directories are lazy, so ceilings cost nothing until used:

- `default` profile: ~2.1 G edge blocks per direction (≈137 G edges — in
  practice bounded by RAM at ~12–13 B/edge), ~4.3 G nodes, ~11 KB fixed
  footprint per `Graph` instance.
- `embedded` profile: ≈266 K edges in 16-edge blocks (128 B forward blocks,
  ~4× less waste per sparse node), ~66 K nodes, 8 reader slots, ~1.3 KB fixed
  footprint. Select with `-Dprofile=embedded`, or in executable builds with
  `pub const azigmuth_options: az.Options = .{ .profile = .embedded };`.
- `edges_per_block` (16/32/64) is itself a profile field for custom profiles.
- Max degree per side per node: `(2²⁶−1) × 64` ≈ **4.29 G** edges.
- Max block groups per node: **4** (`MAX_GROUPS_PER_NODE`).

Implementation notes:

- Per-node state is split into `NodeMeta` (atomic publication word),
  `NodePublished` (double-buffered side descriptors, degrees, sorted bits)
  and `NodeHot` (writer claims, edge-id counter, padded `32 B` stride).
- Edge blocks are struct-of-arrays (profile-sized: 512 B forward / 256 B
  reverse at the default 64 edges per block; 128 B / 64 B at 16), 64-byte
  aligned; per-block live counts live in a one-cache-line sidecar page.

## Basic usage

```zig
const std = @import("std");
const az = @import("azigmuth");

pub fn main() !void {
    var g = try az.Graph.init(std.heap.page_allocator);
    defer g.deinit();

    const a = try g.addNode();
    const b = try g.addNode();

    try g.addEdge(a, b, 0, .{});

    var snapshot = try g.snapshot(std.heap.page_allocator);
    defer snapshot.deinit();

    var it = try snapshot.neighbors(a);
    while (it.next()) |neighbor| {
        std.debug.print("neighbor: {}\n", .{neighbor.index});
    }

    const removal = try g.removeNode(b);
    std.debug.print("removed visible edges: {}\n", .{removal.removed_visible_edges});

    if (removal.left_repair_debt) {
        _ = try g.repairBudgeted(removal.related_live_nodes_touched);
    }

    g.reclaimRetired();

    try g.validate();
}
```

## Builder

```zig
const az = @import("azigmuth");

var builder = try az.GraphBuilder.init(allocator);
defer builder.deinit();

const a = try builder.addNode();
const b = try builder.addNode();
try builder.addEdge(a, b, 0, .{});

var graph = try builder.freeze();
defer graph.deinit();
```

`addEdge` rejects out-of-range node IDs and duplicate edges.  `freeze()` on
an empty builder succeeds and returns a valid zero-node `Graph`.  After
`freeze()` the builder is inert: `addNode()`, `addEdge()`, and `freeze()`
return `error.UnsupportedOperation`, while `deinit()` remains valid.  If
`freeze()` fails, the builder stays reusable; any reserved internal capacity is
an implementation detail.

## Teardown

- `deinit()` is unconditional and requires the caller to ensure that no
  readers, writers, or repairers are still active.
- `deinitChecked()` is the safe teardown path.  It returns
  `error.GraphBusy` when the graph still has active users.
- While `deinitChecked()` is closing the graph to new work, fallible APIs may
  also return `error.GraphBusy` instead of entering the graph.
- Non-fallible accessors (`hasNode`, `nodeCount`, `edgeCount`) return safe
  defaults during that brief closing window.
- Structural repair and retired-memory reclamation are explicit. Use
  `repairNode()`, `repairBudgeted()`, `flushRepairs()`, `debtStats()`, and
  `reclaimRetired()` when you want to inspect or pay maintenance costs
  deliberately before `deinitChecked()`.

## RemoveNode And Repair

`removeNode()` is logically complete when it returns, but it may leave
structural repair debt behind for live predecessors and live destinations.
The return value
`NodeRemovalSummary` reports that aftermath so embeddings can decide whether to
repair now or later. `left_repair_debt` refers to debt left on related live
nodes, not to residual structure on the removed node itself.

`removeNode()` does not perform hidden structural repair or hidden retired-block
reclamation before returning. Repair and reclaim remain caller-driven.

The removed node itself publishes empty forward and reverse adjacency on return;
any remaining tombstone debt lives only on related live nodes.

Live destinations may keep reverse structural tombstones until explicit
maintenance, so `needs_repair_rev` is part of the normal post-`removeNode()`
surface, not a hidden inconsistency.

```zig
const summary = try g.removeNode(node);
if (summary.left_repair_debt) {
    _ = try g.repairBudgeted(summary.related_live_nodes_touched);
}
```

## RepairRequired And Explicit Repair

A mutation that cannot preserve the hard read bounds without a wider rewrite
fails fast with `error.RepairRequired` and leaves the graph unchanged. The
resolution is always the same explicit action: repair the node, then retry.

```zig
const removed = g.removeEdge(a, b) catch |err| switch (err) {
    error.RepairRequired => blk: {
        const summary = try g.repairNode(a);
        _ = summary; // reports flagged vs preventive work per side
        break :blk try g.removeEdge(a, b);
    },
    else => return err,
};
```

`repairNode()` returns a `RepairNodeSummary`: `repaired_*` says a side was
rebuilt, `preventive_*` marks rebuilds done without flagged debt (layout
hardening so the retry succeeds), and `left_repair_debt_*` reports the flag
state after the call. `repairBudgeted()`/`flushRepairs()` never do preventive
work — they only pay debt the graph has already published.

When you want to return memory from retired blocks/groups/tiny slots to the
reusable pools, call `reclaimRetired()` explicitly:

```zig
g.reclaimRetired();
```

The single exception to "no hidden reclaim": if an internal allocation would
otherwise fail while epoch-safe retired storage exists, the engine runs one
last-resort reclaim pass before surfacing `error.OutOfMemory`.

When you want debt observability or an explicit repair flush that drains only
published repair debt sources:

```zig
const stats = try g.debtStats();
_ = stats;

const flush = try g.flushRepairs();
_ = flush;
```

## Batched Insertion

`addEdges()` inserts a whole fan-out from one source with one claim cycle, a
single rebuild of the source side, and one publish per touched node. It is
all-or-nothing: duplicates (in simple-graph mode) or invalid destinations
reject the entire batch before anything is published.

```zig
const inputs = [_]az.EdgeInput{
    .{ .destination = b },
    .{ .destination = c, .relation = 7 },
};
_ = try g.addEdges(a, &inputs);
```

## Point Reads Without Capture

`readSession()` is the cheap counterpart to `snapshot()`: it opens in O(1) and
reads the live published state under RCU, instead of capturing the whole graph
up front. Reads are per-node coherent but not a fixed view.

Open the session once and reuse it: its iterators retain the session's reader
token (one atomic increment per read; a 64-neighbor point read measures
~600–900 ns). Creating a session per read costs ~10× more, and with
`std.heap.page_allocator` every handle allocation is an mmap syscall — prefer
an allocator with reuse for session handles.

```zig
var session = try g.readSession(allocator);
defer session.deinit();

const degree = try session.outDegree(node);
var it = try session.neighbors(node);
defer it.deinit();
while (it.next()) |neighbor| {
    _ = neighbor;
}
```

## Snapshot Read Path

`ReadSnapshot` is the public read/query surface. Snapshot iterators are returned
by value, allocate nothing on creation, and expose `materialize()` when you want
an owned slice. Public adjacency queries, degree queries, and algorithms all go
through `ReadSnapshot`, not `Graph`.

```zig
const ctx = az.Context.init(allocator);

var snapshot = try g.snapshot(ctx);
defer snapshot.deinit();
var it = try snapshot.neighbors(node);
const all = try it.materialize(allocator);
defer allocator.free(all);
// it.next() returns null after materialize()

try snapshot.validate();
const violations = try snapshot.debugValidate(ctx);
defer allocator.free(violations);
```

## Algorithms

```zig
const ctx = az.Context.init(allocator);

var snapshot = try g.snapshot(ctx);
defer snapshot.deinit();

try std.testing.expectEqual(@as(usize, 2), try snapshot.outDegree(start));

var neighbors = try snapshot.neighbors(start);
const all = try neighbors.materialize(allocator);
defer allocator.free(all);

const snap_has_cycle = try snapshot.hasCycle(ctx);
_ = snap_has_cycle;

const snap_bfs = try snapshot.bfs(start, ctx);
defer allocator.free(snap_bfs);

const snap_dfs = try snapshot.dfs(start, ctx);
defer allocator.free(snap_dfs);
```

`ReadSnapshot` is a reusable sealed in-memory graph view. Its algorithms run
against that fixed captured view and do not perform repair or other hidden
maintenance.

The captured view is per-node coherent, not a global point-in-time image:
serialize writers against `snapshot()` if you need one. A live snapshot also
pins a reader epoch (retired storage cannot be reclaimed while it exists).
For long-lived analytical views — or to hand flat arrays to external engines
like DuckDB — materialize a detached CSR copy and release the snapshot:

```zig
var csr = try snapshot.materializeCsr(ctx);
defer csr.deinit(allocator);
snapshot.deinit(); // csr stays valid; nothing pinned

const neighbors_of_n = try csr.outNeighbors(n); // []const u32 into csr.out_targets
_ = neighbors_of_n;
// csr.out_offsets / csr.out_targets are plain flat arrays (classic CSR).
```

Long traversals can be cancelled cooperatively. Attach a `CancelToken` to the
`Context`; `bfs`, `dfs`, and `hasCycle` observe it once per visited node and
abort with `error.Cancelled`. Cancelling is sticky and safe from any thread.
Cancellation is best-effort: a call that finishes its work before reaching a
cancellation checkpoint returns its normal result, so callers must treat
`error.Cancelled` as an optimization for aborting long traversals, not as a
guaranteed outcome. On `error.Cancelled` partial results are freed and the
snapshot stays valid.

```zig
var token = az.CancelToken.init();
const ctx = az.Context{ .allocator = allocator, .cancel_token = &token };

// From a watchdog/timeout thread:
token.cancel();

const order = snapshot.bfs(start, ctx) catch |err| switch (err) {
    error.Cancelled => return, // query aborted
    else => return err,
};
defer allocator.free(order);
```

`Graph.validate()` remains the live fast-path structural check over the mutable
engine state. `snapshot.validate()` is the fast logical/structural check over a
sealed captured view, and `snapshot.debugValidate(ctx)` is the exhaustive
allocating validator over that same captured view. Unlike live
`Graph.debugValidate(ctx)`, snapshot debug validation does not audit free lists,
retired stacks, or other ownership details of the mutable engine.

## Edge Properties

With `GraphOptions.edge_properties` every edge gets a **stable property row
id** that survives repair, repack, and COW. Values live in caller-owned,
comptime-typed columns — the engine stores only the 4-byte row sidecar:

```zig
var g = try az.Graph.initWithOptions(allocator, .{ .edge_properties = true });
defer g.deinit();

var weights = az.EdgeColumn(f32).init(allocator, 0.0);
defer weights.deinit();

const a = try g.addNode();
const b = try g.addNode();
const row = try g.addEdgeWithProperties(a, b, 0, .{});
try weights.set(row, 1.5);

// Later, from any edge-aware read surface:
var snapshot = try g.snapshot(ctx);
defer snapshot.deinit();
var it = try snapshot.outEdges(a);
while (it.next()) |edge| {
    _ = weights.get(edge.property_row);
}

// CSR export carries the row column aligned with targets:
var csr = try snapshot.materializeCsr(ctx);
defer csr.deinit(allocator);
// csr.out_targets[i] ↔ csr.out_rows.?[i]
```

Rows of removed edges recycle after `reclaimRetired()`. With bare columns,
set properties when creating edges (a recycled row keeps the old value until
overwritten) — or use the schema wrapper, which does it for you:

```zig
const Schema = struct { weight: f32 = 0.0, since: u64 = 0 };
var pg = try az.PropertyGraph(Schema).init(allocator, .{});
defer pg.deinit();

const n1 = try pg.addNode();
const n2 = try pg.addNode();
_ = try pg.addEdge(n1, n2, 0, .{}, .{ .weight = 1.5, .since = 1700000000 });
const values = (try pg.edgeValues(n1, n2)).?;  // .{ .weight = 1.5, ... }
_ = values;
// Everything else (snapshots, algorithms, repair) via pg.graph.
```

`NodeColumn(T)` works the same way indexed by `NodeId.index`, which is stable
by construction. `validate()` checks property-row ranges; `debugValidate`
additionally audits global row uniqueness.

## Commands

```sh
zig build check     # compile the library
zig build test      # run non-stress tests
zig build bench -Doptimize=ReleaseFast
zig build stress    # run long-running RCU stress tests
```

## Requirements

Zig 0.16.0
