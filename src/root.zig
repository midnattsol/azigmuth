//! Root module for the Zigraph graph library. `src/root.zig` defines the public
//! API surface and re-exports the stable public types; everything else in the
//! source tree is implementation detail not covered by the stability contract.
//!
//! Usage with Graph:
//!   const graphz = @import("graphz");
//!   var g = try graphz.Graph.init(allocator);
//!   defer g.deinit();
//!   const n = try g.addNode();
//!   const m = try g.addNode();
//!   try g.addEdge(n, m, 0, .{});
//!
//!   var it = try g.neighbors(n);
//!   defer it.deinit();
//!   while (it.next()) |neighbor| { ... }
//!   // Iterators are single-owner values; copying and using multiple copies
//!   // is unsupported.
//!
//!   // materialize drains without consuming the iterator — deinit() still required:
//!   var it2 = try g.neighbors(n);
//!   defer it2.deinit();
//!   const all = try it2.materialize(allocator);
//!   defer allocator.free(all);
//!
//!   const order = try graphz.algorithms.bfs(g, n, allocator);
//!   defer allocator.free(order);
//!
//! Usage with GraphBuilder:
//!   var builder = try graphz.GraphBuilder.init(allocator);
//!   defer builder.deinit();  // required even after freeze()
//!   const a = try builder.addNode();
//!   const b = try builder.addNode();
//!   try builder.addEdge(a, b, 0, .{});
//!   var g2 = try builder.freeze();  // builder becomes inert
//!   defer g2.deinit();              // graph lifetime independent of builder

const graph = @import("graph.zig");
const public_iterator = @import("neighbor_iterator.zig");
const public_algorithms = @import("api/public_algorithms.zig");
const public_graph = @import("api/public_graph.zig");
const public_builder = @import("api/public_builder.zig");

// ── Core types ────────────────────────────────────────────────────────
pub const NodeId = graph.NodeId;
pub const Edge = graph.Edge;
pub const EdgeFlags = graph.EdgeFlags;
pub const NodeFlags = graph.NodeFlags;

// ── Multigraph types ──────────────────────────────────────────────────
pub const EdgeId = graph.EdgeId;
pub const EdgeRef = graph.EdgeRef;
pub const GraphOptions = graph.GraphOptions;
pub const NodeRemovalSummary = graph.NodeRemovalSummary;

// ── Graph engine ──────────────────────────────────────────────────────
pub const Graph = public_graph.Graph;
pub const GraphBuilder = public_builder.GraphBuilder;
pub const algorithms = public_algorithms;
pub const NeighborIterator = public_iterator.NeighborIterator;
pub const OutEdgeIterator = graph.OutEdgeIterator;
pub const GraphError = graph.GraphError;
pub const DeinitError = graph.DeinitError;
pub const Violation = graph.Violation;
