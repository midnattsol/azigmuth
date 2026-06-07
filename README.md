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

- Max degree per side per node: **4,194,240** (`65,535 * 64` edges).
- Max block groups per node: **4** (`MAX_GROUPS_PER_NODE`).
- Supernodes (> 4.19M edges in one direction) are not supported in the
  current storage format — accepted architecture trade-off.

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

    var it = try g.neighbors(a);
    defer it.deinit();
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
- Heavy maintenance is explicit. Use `repairNode()`, `repairBudgeted()`, and
  `reclaimRetired()` when you want to pay maintenance costs deliberately before
  `deinitChecked()`.

## RemoveNode And Repair

`removeNode()` is logically complete when it returns, but it may leave
structural repair debt behind for live predecessors and live destinations.
The return value
`NodeRemovalSummary` reports that aftermath so embeddings can decide whether to
repair now or later.

Live destinations may keep reverse structural tombstones until explicit
maintenance, so `needs_repair_rev` is part of the normal post-`removeNode()`
surface, not a hidden inconsistency.

```zig
const summary = try g.removeNode(node);
if (summary.left_repair_debt) {
    _ = try g.repairBudgeted(summary.related_live_nodes_touched);
}
```

When you want to return memory from retired blocks/groups to the reusable pools,
call `reclaimRetired()` explicitly:

```zig
g.reclaimRetired();
```

## Materialize

`NeighborIterator` is returned by value, allocates nothing on creation, and is
the canonical iterator type used directly by the public API. `materialize()`
drains the iterator without consuming it, so `deinit()` is still required.

```zig
var it = try g.neighbors(node);
defer it.deinit();
const all = try it.materialize(allocator);
defer allocator.free(all);
// it.next() returns null after materialize()
```

## Algorithms

```zig
const order = try graphz.algorithms.bfs(g, start, allocator);
defer allocator.free(order);  // may be empty (len == 0)

const depth_order = try graphz.algorithms.dfs(g, start, allocator);
defer allocator.free(depth_order);  // may be empty (len == 0)

const has_cycle = try graphz.algorithms.hasCycle(g, allocator);
```

## Commands

```sh
zig build check     # compile the library
zig build test      # run non-stress tests
zig build bench -Doptimize=ReleaseFast
zig build stress    # run long-running RCU stress tests
```

## Requirements

Zig 0.16.0
