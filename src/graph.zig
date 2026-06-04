const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");

// ── Implementation modules ───────────────────────────────────────────────
const page_ops = @import("storage/page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");
const mutation = @import("mutation.zig");
const query = @import("query.zig");
const repair = @import("maintenance/repair.zig");
const validate_mod = @import("maintenance/validate.zig");
const node_validity = @import("core/node_validity.zig");

// ── Re-exports for test access ──────────────────────────────────────────
pub const constants_mod = constants;
pub const types_mod = types;
pub const graph_core_mod = graph_core;
pub const page_ops_mod = page_ops;
pub const adjacency_mod = adjacency;
pub const rcu_mod = rcu;
pub const mutation_mod = mutation;
pub const mutation_common_mod = @import("mutation/common.zig");
pub const repair_mod = repair;
pub const node_validity_mod = node_validity;
pub const bfs_mod = @import("algorithms/bfs.zig");
pub const dfs_mod = @import("algorithms/dfs.zig");
pub const cycle_mod = @import("algorithms/cycle.zig");

// ── Re-exports ───────────────────────────────────────────────────────────
pub const NodeId = types.NodeId;
pub const GraphError = types.GraphError;
pub const DeinitError = error{ GraphBusy };
pub const NodeFlags = types.NodeFlags;
pub const EdgeFlags = types.EdgeFlags;
pub const Edge = types.Edge;
pub const NodeAdj = types.NodeAdj;
pub const NodeBuffer = types.NodeBuffer;
pub const EdgeBlockFwd = types.EdgeBlockFwd;
pub const EdgeBlockRev = types.EdgeBlockRev;
pub const EdgeBlockGroup = types.EdgeBlockGroup;
pub const RetiredBlock = types.RetiredBlock;
pub const Violation = types.Violation;
pub const NeighborIterator = query.NeighborIterator;

pub const NODES_PER_PAGE = constants.NODES_PER_PAGE;
pub const EDGE_BLOCKS_PER_PAGE = constants.EDGE_BLOCKS_PER_PAGE;
pub const EDGE_GROUPS_PER_PAGE = constants.EDGE_GROUPS_PER_PAGE;
pub const GraphCore = graph_core.GraphCore;

fn freeAtomicPages(comptime T: type, allocator: std.mem.Allocator, directory: []std.atomic.Value(usize), entries_per_page: usize) void {
    for (directory) |*entry| {
        const raw = entry.load(.acquire);
        if (raw == 0) continue;
        const page_ptr: [*]T = @ptrFromInt(raw);
        allocator.free(page_ptr[0..entries_per_page]);
    }
}

pub const Graph = struct {
    graph: graph_core.GraphCore,

    // ── Lifecycle ─────────────────────────────────────────────────────

    fn hasActiveReadersOrWriters(core: *const graph_core.GraphCore) bool {
        if (core.active_calls.load(.acquire) != 0) return true;
        if (core.active_writers.load(.acquire) != 0) return true;
        if (core.active_repairers.load(.acquire) != 0) return true;
        if (core.reader_epoch_overflow.load(.acquire) != 0) return true;
        for (&core.reader_epochs) |*slot| {
            if (slot.load(.acquire) != 0) return true;
        }
        return false;
    }

    fn checkOpen(core: *const graph_core.GraphCore) GraphError!void {
        if (core.closing.load(.acquire)) return error.GraphBusy;
    }

    /// Begin a mutation call.  Ensures the graph is open and registers
    /// the call in `active_calls`.  Double-checks `closing` after
    /// incrementing to close the check-then-set race window.
    fn beginMutation(core: *graph_core.GraphCore) GraphError!void {
        if (core.closing.load(.acquire)) return error.GraphBusy;
        _ = core.active_calls.fetchAdd(1, .acq_rel);
        if (core.closing.load(.acquire)) {
            _ = core.active_calls.fetchSub(1, .acq_rel);
            return error.GraphBusy;
        }
    }

    pub fn init(allocator: std.mem.Allocator) !Graph {
        const first_page = try allocator.alloc(types.NodeBuffer, constants.NODES_PER_PAGE);
        errdefer allocator.free(first_page);
        @memset(first_page, std.mem.zeroes(types.NodeBuffer));

        var state_value = graph_core.GraphCore{
            .allocator = allocator,
            .repair_fwd = .empty,
            .repair_rev = .empty,
        };

        state_value.node_pages_pages[0].store(@intFromPtr(first_page.ptr), .release);

        return .{ .graph = state_value };
    }

    pub fn deinit(self: *Graph) void {
        std.debug.assert(!hasActiveReadersOrWriters(&self.graph));

        const alloc = self.graph.allocator;
        freeAtomicPages(types.NodeBuffer, alloc, self.graph.node_pages_pages[0..], constants.NODES_PER_PAGE);
        freeAtomicPages(types.EdgeBlockFwd, alloc, self.graph.edge_blocks_fwd_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockRev, alloc, self.graph.edge_blocks_rev_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockGroup, alloc, self.graph.edge_block_group_pages[0..], constants.EDGE_GROUPS_PER_PAGE);
        freeAtomicPages(types.BlockMeta, alloc, self.graph.edge_blocks_fwd_meta_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.BlockMeta, alloc, self.graph.edge_blocks_rev_meta_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.BlockMeta, alloc, self.graph.edge_block_group_meta_pages[0..], constants.EDGE_GROUPS_PER_PAGE);

        self.graph.repair_fwd.deinit(alloc);
        self.graph.repair_rev.deinit(alloc);
    }

    pub fn deinitChecked(self: *Graph) DeinitError!void {
        self.graph.closing.store(true, .release);
        if (hasActiveReadersOrWriters(&self.graph)) {
            self.graph.closing.store(false, .release);
            return error.GraphBusy;
        }
        self.deinit();
        // closing stays true — graph is now dead
    }

    // ── Node API ──────────────────────────────────────────────────────

    pub fn addNode(self: *Graph) !types.NodeId {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);

        while (true) {
            const index = self.graph.publishedNodeCount();
            const page = page_ops.pageOf(index, constants.NODES_PER_PAGE);
            _ = try page_ops.ensureNodePage(&self.graph, page);

            if (self.graph.node_count.cmpxchgWeak(index, index + 1, .acq_rel, .acquire) == null) {
                return types.NodeId{ .index = index };
            }
        }
    }

    pub fn nodeCount(self: *const Graph) usize {
        if (self.graph.closing.load(.acquire)) return 0;
        return self.graph.publishedNodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        if (self.graph.closing.load(.acquire)) return 0;
        return self.graph.edge_count.load(.acquire);
    }

    pub fn hasNode(self: *const Graph, id: types.NodeId) bool {
        if (self.graph.closing.load(.acquire)) return false;
        return node_validity.isNodeLive(&self.graph, id);
    }

    // ── Internal helpers (test/debug access, not public API) ───────────

    pub fn nodeAt(self: *Graph, node: types.NodeId) !*types.NodeBuffer {
        try node_validity.ensureLiveNode(&self.graph, node);
        return page_ops.nodeAt(&self.graph, node);
    }

    pub fn nodeAtConst(self: *const Graph, node: types.NodeId) !*const types.NodeBuffer {
        try node_validity.ensureLiveNode(&self.graph, node);
        return page_ops.nodeAtConst(&self.graph, node);
    }

    pub fn nodePageCount(self: *const Graph) usize {
        const node_count = self.graph.publishedNodeCount();
        if (node_count == 0) return 1;
        return @as(usize, @intCast(page_ops.pageOf(node_count - 1, constants.NODES_PER_PAGE) + 1));
    }

    pub fn allocBlockFwd(self: *Graph) !u32 {
        return page_ops.allocBlock(&self.graph, .fwd);
    }

    pub fn allocBlockRev(self: *Graph) !u32 {
        return page_ops.allocBlock(&self.graph, .rev);
    }

    pub fn allocGroup(self: *Graph) !u32 {
        return page_ops.allocGroup(&self.graph);
    }

    pub fn freeGroup(self: *Graph, idx: u32) void {
        page_ops.freeGroup(&self.graph, idx);
    }

    pub fn hasEdgeInAdj(self: *const Graph, adj: types.NodeAdj, target: u32) bool {
        return adjacency.hasEdgeInAdj(&self.graph, adj, target);
    }

    pub fn publishedNodeAdj(self: *const Graph, node: types.NodeId) !types.NodeAdj {
        return adjacency.publishedNodeAdj(&self.graph, node);
    }

    pub const ReaderToken = rcu.ReaderToken;

    pub fn readerEnter(self: *Graph) GraphError!ReaderToken {
        return try rcu.readerEnter(&self.graph);
    }

    pub fn readerExit(self: *Graph, token: ReaderToken) void {
        rcu.readerExit(&self.graph, token);
    }

    pub fn retireBlockFwd(self: *Graph, block_idx: u32) !void {
        return rcu.retireBlockFwd(&self.graph, block_idx);
    }

    pub fn retireBlockRev(self: *Graph, block_idx: u32) !void {
        return rcu.retireBlockRev(&self.graph, block_idx);
    }

    pub fn bumpEpoch(self: *Graph) void {
        rcu.bumpEpoch(&self.graph);
    }

    pub fn reclaimRetired(self: *Graph) void {
        rcu.reclaimRetired(&self.graph);
    }

    // ── Validation ────────────────────────────────────────────────────

    pub fn validate(self: *const Graph) GraphError!void {
        return validate_mod.validate(&self.graph);
    }

    pub fn debugValidate(self: *const Graph, allocator: std.mem.Allocator) GraphError![]types.Violation {
        return validate_mod.debugValidate(&self.graph, allocator);
    }

    // ── Query API ─────────────────────────────────────────────────────

    pub fn neighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        return query.neighbors(&self.graph, node);
    }

    pub fn inNeighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        return query.inNeighbors(&self.graph, node);
    }

    pub fn outDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        try checkOpen(&self.graph);
        return query.outDegree(&self.graph, node);
    }

    pub fn inDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        try checkOpen(&self.graph);
        return query.inDegree(&self.graph, node);
    }

    // ── Repair API ────────────────────────────────────────────────────

    pub fn repairNode(self: *Graph, node: types.NodeId) GraphError!void {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);
        return repair.repairNode(&self.graph, node);
    }

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) GraphError!usize {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);
        return repair.repairBudgeted(&self.graph, max_nodes);
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub fn addEdge(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);
        return mutation.addEdge(&self.graph, source, destination, relation, flags);
    }

    pub fn removeEdge(self: *Graph, source: types.NodeId, destination: types.NodeId) GraphError!bool {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);
        return mutation.removeEdge(&self.graph, source, destination);
    }

    pub fn removeNode(self: *Graph, node: types.NodeId) GraphError!void {
        try beginMutation(&self.graph);
        defer _ = self.graph.active_calls.fetchSub(1, .acq_rel);
        return mutation.removeNode(&self.graph, node);
    }
};

pub const GraphBuilder = @import("api/builder.zig").GraphBuilder;
