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
//!   const ctx = graphz.Context.init(allocator);
//!   var snapshot = try g.snapshot(ctx);
//!   defer snapshot.deinit();
//!   var neighbors = try snapshot.neighbors(n);
//!   const all = try neighbors.materialize(allocator);
//!   defer allocator.free(all);
//!   const order = try snapshot.bfs(n, ctx);
//!   defer allocator.free(order);
//!   const has_cycle = try snapshot.hasCycle(ctx);
//!   _ = has_cycle;
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
const public_graph = @import("api/public_graph.zig");
const public_snapshot = @import("api/public_snapshot.zig");
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
pub const RepairFlushSummary = graph.RepairFlushSummary;
pub const DebtStats = graph.DebtStats;

// ── Graph engine ──────────────────────────────────────────────────────
pub const Graph = public_graph.Graph;
pub const ReadSnapshot = public_snapshot.ReadSnapshot;
pub const GraphBuilder = public_builder.GraphBuilder;
pub const SnapshotNeighborIterator = graph.SnapshotNeighborIterator;
pub const SnapshotOutEdgeIterator = graph.SnapshotOutEdgeIterator;
pub const GraphError = graph.GraphError;
pub const DeinitError = graph.DeinitError;
pub const Violation = graph.Violation;

// ── Algorithms ────────────────────────────────────────────────────────
pub const Context = @import("algorithms/context.zig").Context;
