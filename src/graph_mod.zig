//! Test-only facade exposing white-box internals. This is not part of the
//! public `azigmuth` stability contract.

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
pub const side_ops_mod = @import("adjacency/side_ops.zig");
pub const node_published_mod = @import("storage/node/published.zig");
pub const node_meta_mod = @import("storage/node/meta.zig");
pub const mutation_common_mod = @import("mutation/common.zig");
pub const repair_mod = repair;
pub const query_mod = neighbor_iter;
pub const bfs_mod = @import("algorithms/bfs.zig");
pub const dfs_mod = @import("algorithms/dfs.zig");
pub const cycle_mod = @import("algorithms/cycle.zig");
pub const snapshot_view_mod = @import("query/snapshot/view.zig");
pub const validate_common_mod = @import("maintenance/validate/common.zig");
pub const validate_sums_mod = @import("maintenance/validate/sums.zig");
pub const validate_shape_mod = @import("maintenance/validate/shape.zig");
pub const validate_run_search_mod = @import("maintenance/validate/run_search.zig");
pub const layout_debt_mod = @import("maintenance/layout_debt.zig");
pub const rcu_mod = @import("concurrency/rcu.zig");
pub const node_bitmap_mod = @import("core/node_bitmap.zig");
pub const tiny_mod = @import("storage/node/tiny.zig");
pub const remove_fast_path_mod = @import("mutation/edge/remove/fast_path.zig");
pub const remove_rebuild_common_mod = @import("mutation/edge/remove/rebuild/common.zig");
pub const node_access_mod = @import("core/node_access.zig");
pub const radix_directory_mod = @import("storage/radix_directory.zig");
pub const persistence_mod = @import("storage/persistence.zig");
pub const wayfind_mod = @import("query/wayfind.zig");
pub const wayfind_ir_mod = @import("query/wayfind/ir.zig");
pub const wayfind_builder_mod = @import("query/wayfind/builder.zig");
pub const wayfind_exec_mod = @import("query/wayfind/exec.zig");
pub const wayfind_parser_mod = @import("query/wayfind/parser.zig");
pub const adjacency_runs_mod = @import("adjacency/runs.zig");
pub const algorithms_context_mod = @import("algorithms/context.zig");

pub const profile_mod = @import("core/profile.zig");
pub const properties_mod = @import("properties.zig");
pub const Profile = profile_mod.Profile;
pub const Options = profile_mod.Options;

pub const NodeId = types.NodeId;
pub const GraphCore = graph_core.GraphCore;

pub const Graph = graph.Graph;
pub const GraphBuilder = @import("internal/builder.zig").GraphBuilder;
pub const snapshotDegree = neighbor_iter.snapshotDegree;
pub const materializeConsuming = neighbor_iter.materializeConsuming;
pub const materializeExactConsuming = neighbor_iter.materializeExactConsuming;
