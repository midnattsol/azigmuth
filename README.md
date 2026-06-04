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
const order = try g.bfs(start, allocator);
defer allocator.free(order);  // may be empty (len == 0)

const order = try g.dfs(start, allocator);
defer allocator.free(order);  // may be empty (len == 0)

const has_cycle = try g.hasCycle(allocator);
```

## Commands

```sh
zig build check     # compile the library
zig build test      # run non-stress tests
zig build stress    # run long-running RCU stress tests
```

## Requirements

Zig 0.16.0
