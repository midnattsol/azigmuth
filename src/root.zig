//! Root module for the Zigraph graph library.
//!
//! Usage:
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
//!
//!   const order = try g.bfs(n, allocator);
//!   defer allocator.free(order);

const graph = @import("graph.zig");
const public_graph = @import("api/public_graph.zig");
const public_builder = @import("api/public_builder.zig");
const public_iterator = @import("api/public_iterator.zig");

// ── Core types ────────────────────────────────────────────────────────
pub const NodeId = graph.NodeId;
pub const Edge = graph.Edge;
pub const EdgeFlags = graph.EdgeFlags;
pub const NodeFlags = graph.NodeFlags;

// ── Graph engine ──────────────────────────────────────────────────────
pub const Graph = public_graph.Graph;
pub const GraphBuilder = public_builder.GraphBuilder;
pub const NeighborIterator = public_iterator.NeighborIterator;
pub const GraphError = graph.GraphError;
pub const DeinitError = graph.DeinitError;
pub const Violation = graph.Violation;
