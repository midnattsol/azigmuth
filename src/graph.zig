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
const bfs_mod = @import("algorithms/bfs.zig");
const dfs_mod = @import("algorithms/dfs.zig");
const cycle_mod = @import("algorithms/cycle.zig");

// ── Internal API used by public wrappers ─────────────────────────────────
pub const NodeId = types.NodeId;
pub const GraphError = types.GraphError;
pub const DeinitError = error{ GraphBusy };
pub const NodeFlags = types.NodeFlags;
pub const EdgeFlags = types.EdgeFlags;
pub const Edge = types.Edge;
pub const Violation = types.Violation;
pub const NeighborIterator = query.NeighborIterator;

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
        if (core.activeCallCount() != 0) return true;
        if (core.active_writers.load(.acquire) != 0) return true;
        if (core.active_repairers.load(.acquire) != 0) return true;
        if (core.reader_epoch_overflow.load(.acquire) != 0) return true;
        for (&core.reader_epochs) |*slot| {
            if (slot.load(.acquire) != 0) return true;
        }
        return false;
    }

    fn beginCall(core: *graph_core.GraphCore) GraphError!void {
        while (true) {
            const state = core.callState();
            if ((state & graph_core.GraphCore.CALL_CLOSING_BIT) != 0) return error.GraphBusy;
            if ((state & graph_core.GraphCore.CALL_ACTIVE_MASK) == graph_core.GraphCore.CALL_ACTIVE_MASK) return error.GraphBusy;
            const desired = state + 1;
            if (core.call_state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) return;
        }
    }

    fn beginCallNoError(core: *graph_core.GraphCore) bool {
        while (true) {
            const state = core.callState();
            if ((state & graph_core.GraphCore.CALL_CLOSING_BIT) != 0) return false;
            if ((state & graph_core.GraphCore.CALL_ACTIVE_MASK) == graph_core.GraphCore.CALL_ACTIVE_MASK) return false;
            const desired = state + 1;
            if (core.call_state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) return true;
        }
    }

    fn endCall(core: *graph_core.GraphCore) void {
        _ = core.call_state.fetchSub(1, .acq_rel);
    }

    fn tryClose(core: *graph_core.GraphCore) DeinitError!void {
        while (true) {
            const state = core.callState();
            if ((state & graph_core.GraphCore.CALL_CLOSING_BIT) != 0) return error.GraphBusy;
            const desired = state | graph_core.GraphCore.CALL_CLOSING_BIT;
            if (core.call_state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) return;
        }
    }

    fn clearClose(core: *graph_core.GraphCore) void {
        _ = core.call_state.fetchAnd(graph_core.GraphCore.CALL_ACTIVE_MASK, .acq_rel);
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
        try tryClose(&self.graph);
        if (hasActiveReadersOrWriters(&self.graph)) {
            clearClose(&self.graph);
            return error.GraphBusy;
        }
        self.deinit();
        // closing bit stays set in the dead handle until public wrapper frees it.
    }

    // ── Node API ──────────────────────────────────────────────────────

    pub fn addNode(self: *Graph) !types.NodeId {
        try beginCall(&self.graph);
        defer endCall(&self.graph);

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
        if (!beginCallNoError(@constCast(&self.graph))) return 0;
        defer endCall(@constCast(&self.graph));
        return self.graph.publishedNodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        if (!beginCallNoError(@constCast(&self.graph))) return 0;
        defer endCall(@constCast(&self.graph));
        return self.graph.edge_count.load(.acquire);
    }

    pub fn hasNode(self: *const Graph, id: types.NodeId) bool {
        if (!beginCallNoError(@constCast(&self.graph))) return false;
        defer endCall(@constCast(&self.graph));
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
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
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
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return validate_mod.validate(&self.graph);
    }

    pub fn debugValidate(self: *const Graph, allocator: std.mem.Allocator) GraphError![]types.Violation {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return validate_mod.debugValidate(&self.graph, allocator);
    }

    // ── Query API ─────────────────────────────────────────────────────

    pub fn neighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return query.neighbors(&self.graph, node);
    }

    pub fn inNeighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return query.inNeighbors(&self.graph, node);
    }

    pub fn outDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return query.outDegree(&self.graph, node);
    }

    pub fn inDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return query.inDegree(&self.graph, node);
    }

    pub fn bfs(self: *const Graph, start: types.NodeId, allocator: std.mem.Allocator) GraphError![]types.NodeId {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return bfs_mod.bfs(&self.graph, start, allocator);
    }

    pub fn dfs(self: *const Graph, start: types.NodeId, allocator: std.mem.Allocator) GraphError![]types.NodeId {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return dfs_mod.dfs(&self.graph, start, allocator);
    }

    pub fn hasCycle(self: *const Graph, allocator: std.mem.Allocator) GraphError!bool {
        try beginCall(@constCast(&self.graph));
        defer endCall(@constCast(&self.graph));
        return cycle_mod.hasCycle(&self.graph, allocator);
    }

    // ── Repair API ────────────────────────────────────────────────────

    pub fn repairNode(self: *Graph, node: types.NodeId) GraphError!void {
        try beginCall(&self.graph);
        defer endCall(&self.graph);
        return repair.repairNode(&self.graph, node);
    }

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) GraphError!usize {
        try beginCall(&self.graph);
        defer endCall(&self.graph);
        return repair.repairBudgeted(&self.graph, max_nodes);
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub fn addEdge(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        try beginCall(&self.graph);
        defer endCall(&self.graph);
        return mutation.addEdge(&self.graph, source, destination, relation, flags);
    }

    pub fn removeEdge(self: *Graph, source: types.NodeId, destination: types.NodeId) GraphError!bool {
        try beginCall(&self.graph);
        defer endCall(&self.graph);
        return mutation.removeEdge(&self.graph, source, destination);
    }

    pub fn removeNode(self: *Graph, node: types.NodeId) GraphError!void {
        try beginCall(&self.graph);
        defer endCall(&self.graph);
        return mutation.removeNode(&self.graph, node);
    }
};

pub const GraphBuilder = @import("internal/builder.zig").GraphBuilder;
