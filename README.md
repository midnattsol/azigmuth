# graphz

A directed graph storage library for Zig based on the RB-CSR design in `RFC.md`.

- page-based node and edge-block pools
- forward and reverse adjacency
- lock-free reader iterators via per-node RCU snapshots
- sorted fixed-size edge blocks with dense occupancy masks
- local repair and validation
- tombstone-based node deletion (Phase 2) with debt/repair cleanup
- a `GraphBuilder` bulk-construction handle

## Design limits

- Max degree per side per node: **16,777,216** (`262,144 * 64` edges).
- Max block groups per node: **4** (`MAX_GROUPS_PER_NODE`).
- Supernodes (> 16.7M edges in one direction) are not supported in the
  current storage format — accepted architecture trade-off.

Implementation notes:

- Const read paths compose adjacency from `NodeMeta + NodePublished`.
- `NodeHot` lives in padded `hot_layout.Slot` entries (default `32 B` stride).
- `NodeBuffer` remains as the mutation staging / compatibility layer, not the
  canonical const read source for published adjacency.

## Basic usage

```zig
const std = @import("std");
const gz = @import("graphz");

pub fn main() !void {
    var g = try gz.Graph.init(std.heap.page_allocator);
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
const gz = @import("graphz");

var builder = try gz.GraphBuilder.init(allocator);
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

## Point Reads Without Capture

`readSession()` is the cheap counterpart to `snapshot()`: it opens in O(1) and
reads the live published state under RCU, instead of capturing the whole graph
up front. Reads are per-node coherent but not a fixed view.

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
const ctx = gz.Context.init(allocator);

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
const ctx = gz.Context.init(allocator);

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

`Graph.validate()` remains the live fast-path structural check over the mutable
engine state. `snapshot.validate()` is the fast logical/structural check over a
sealed captured view, and `snapshot.debugValidate(ctx)` is the exhaustive
allocating validator over that same captured view. Unlike live
`Graph.debugValidate(ctx)`, snapshot debug validation does not audit free lists,
retired stacks, or other ownership details of the mutable engine.

## Commands

```sh
zig build check     # compile the library
zig build test      # run non-stress tests
zig build bench -Doptimize=ReleaseFast
zig build stress    # run long-running RCU stress tests
```

## Requirements

Zig 0.16.0
