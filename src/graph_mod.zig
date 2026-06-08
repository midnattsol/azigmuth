//! Test-only facade exposing white-box internals. This is not part of the
//! public `graphz` stability contract.

const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");
const adjacency = @import("adjacency/mod.zig");
const mutation = @import("mutation.zig");
const repair = @import("maintenance/repair.zig");
const graph = @import("graph.zig");
const neighbor_iter = @import("query/neighbor_iterator.zig");

pub const constants_mod = constants;
pub const types_mod = types;
pub const graph_core_mod = graph_core;
pub const page_ops_mod = page_ops;
pub const adjacency_mod = adjacency;
pub const mutation_common_mod = @import("mutation/common.zig");
pub const repair_mod = repair;
pub const query_mod = neighbor_iter;
pub const bfs_mod = @import("algorithms/bfs.zig");
pub const dfs_mod = @import("algorithms/dfs.zig");
pub const cycle_mod = @import("algorithms/cycle.zig");
pub const snapshot_view_mod = @import("query/snapshot_view.zig");

pub const NodeId = types.NodeId;
pub const NodeBuffer = types.NodeBuffer;
pub const GraphCore = graph_core.GraphCore;

pub const Graph = graph.Graph;
pub const GraphBuilder = @import("internal/builder.zig").GraphBuilder;
pub const snapshotDegree = neighbor_iter.snapshotDegree;
pub const materializeConsuming = neighbor_iter.materializeConsuming;
pub const materializeExactConsuming = neighbor_iter.materializeExactConsuming;
