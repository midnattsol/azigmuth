//! Mutation facade — edge and node mutation entry points.
//!
//! The implementation now lives under `src/mutation/`:
//!   - `mutation/common.zig` for shared claim/writer/adjacency helpers
//!   - `mutation/edge.zig` for edge mutations
//!   - `mutation/node.zig` for node-oriented mutations

const edge = @import("mutation/edge/mod.zig");
const node = @import("mutation/node/mod.zig");

pub const addEdge = edge.addEdge;
pub const addEdgeWithId = edge.addEdgeWithId;
pub const addEdges = edge.addEdges;
pub const addNode = node.addNode;
pub const removeEdge = edge.removeEdge;
pub const removeEdgeWithId = edge.removeEdgeWithId;
pub const removeNode = node.removeNode;
