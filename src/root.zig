//! Root module for the Zigraph graph library.
//!
//! Usage:
//!   var g = try Graph.init(allocator);
//!   defer g.deinit(allocator);
//!   const n = try g.addNode();
//!   try g.addEdge(n, m, 0, 0);

const graph = @import("graph.zig");

// ── Core types ────────────────────────────────────────────────────────
pub const NodeId = graph.NodeId;
pub const Edge = graph.Edge;
pub const EdgeFlags = graph.EdgeFlags;
pub const NodeFlags = graph.NodeFlags;

// ── Graph engine ──────────────────────────────────────────────────────
pub const Graph = graph.Graph;
pub const GraphError = graph.GraphError;
pub const Violation = graph.Violation;
pub const NeighborIterator = graph.NeighborIterator;

// ── Algorithms ────────────────────────────────────────────────────────
// Temporarily not exported while Graph neighbor-iterator API is being
// migrated to the new mutable core.
