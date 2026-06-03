# graphz

A directed graph storage library for Zig based on the RB-CSR design in `RFC.md`.

Phase 1 focuses on a mutable directed graph with:

- page-based node and edge-block pools
- forward and reverse adjacency
- lock-free reader iterators via per-node RCU snapshots
- sorted fixed-size edge blocks with dense occupancy masks
- local repair and validation
- a `GraphBuilder` convenience wrapper for bulk construction

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
`freeze()` the builder is inert — only `deinit()` is valid.

## Materialize

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
