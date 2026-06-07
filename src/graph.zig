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
const stats_mod = @import("maintenance/stats.zig");
const validate_mod = @import("maintenance/validate.zig");
const read_session_mod = @import("algorithms/read_session.zig");
const node_bitmap = @import("core/node_bitmap.zig");
const node_validity = @import("core/node_validity.zig");
const out_edge_iter = @import("out_edge_iterator.zig");

// ── Internal API used by public wrappers ─────────────────────────────────
pub const NodeId = types.NodeId;
pub const GraphError = types.GraphError;
pub const DeinitError = error{GraphBusy};
pub const NodeFlags = types.NodeFlags;
pub const EdgeFlags = types.EdgeFlags;
pub const Edge = types.Edge;
pub const Violation = types.Violation;
pub const NeighborIterator = query.NeighborIterator;
pub const OutEdgeIterator = out_edge_iter.OutEdgeIterator;
pub const EdgeId = types.EdgeId;
pub const EdgeRef = types.EdgeRef;
pub const GraphOptions = types.GraphOptions;
pub const NodeRemovalSummary = types.NodeRemovalSummary;
pub const RepairFlushSummary = types.RepairFlushSummary;
pub const DebtStats = types.DebtStats;
pub const ReadSession = read_session_mod.ReadSession;

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

    fn tryBeginCall(core: *graph_core.GraphCore) bool {
        while (true) {
            const state = core.callState();
            if ((state & graph_core.GraphCore.CALL_CLOSING_BIT) != 0) return false;
            if ((state & graph_core.GraphCore.CALL_ACTIVE_MASK) == graph_core.GraphCore.CALL_ACTIVE_MASK) return false;
            const desired = state + 1;
            if (core.call_state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) return true;
        }
    }

    fn beginCall(core: *graph_core.GraphCore) GraphError!void {
        if (!tryBeginCall(core)) return error.GraphBusy;
    }

    fn endCall(core: *graph_core.GraphCore) void {
        _ = core.call_state.fetchSub(1, .acq_rel);
    }

    fn beginConstCall(self: *const Graph) GraphError!*graph_core.GraphCore {
        const core = @constCast(&self.graph);
        try beginCall(core);
        return core;
    }

    fn beginMutCall(self: *Graph) GraphError!*graph_core.GraphCore {
        try beginCall(&self.graph);
        return &self.graph;
    }

    fn tryBeginConstCall(self: *const Graph) ?*graph_core.GraphCore {
        const core = @constCast(&self.graph);
        if (!tryBeginCall(core)) return null;
        return core;
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

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        options: types.GraphOptions,
    ) !Graph {
        const first_page = try allocator.alloc(types.NodeBuffer, constants.NODES_PER_PAGE);
        errdefer allocator.free(first_page);
        @memset(first_page, std.mem.zeroes(types.NodeBuffer));

        var state_value = graph_core.GraphCore{
            .allocator = allocator,
            .multigraph_enabled = options.multigraph,
            .repair_fwd = .empty,
            .repair_rev = .empty,
        };

        state_value.node_pages_pages[0].store(@intFromPtr(first_page.ptr), .release);

        return .{ .graph = state_value };
    }

    pub fn init(allocator: std.mem.Allocator) !Graph {
        return initWithOptions(allocator, .{});
    }

    pub fn deinit(self: *Graph) void {
        if (hasActiveReadersOrWriters(&self.graph)) {
            std.debug.panic(
                "Graph.deinit called while active: calls={d}, writers={d}, repairers={d}, overflow={d}",
                .{
                    self.graph.activeCallCount(),
                    self.graph.active_writers.load(.acquire),
                    self.graph.active_repairers.load(.acquire),
                    self.graph.reader_epoch_overflow.load(.acquire),
                },
            );
        }

        const alloc = self.graph.allocator;
        freeAtomicPages(types.NodeBuffer, alloc, self.graph.node_pages_pages[0..], constants.NODES_PER_PAGE);
        freeAtomicPages(std.atomic.Value(u64), alloc, self.graph.repair_queued_fwd_pages[0..], node_bitmap.WORDS_PER_PAGE);
        freeAtomicPages(std.atomic.Value(u64), alloc, self.graph.repair_queued_rev_pages[0..], node_bitmap.WORDS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockFwd, alloc, self.graph.edge_blocks_fwd_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockRev, alloc, self.graph.edge_blocks_rev_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockGroup, alloc, self.graph.edge_block_group_pages[0..], constants.EDGE_GROUPS_PER_PAGE);
        if (self.graph.multigraph_enabled) freeAtomicPages(types.EdgeBlockFwdIds, alloc, self.graph.edge_blocks_fwd_id_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
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
        const core = try self.beginMutCall();
        defer endCall(core);

        while (true) {
            const index = core.publishedNodeCount();
            const page = page_ops.pageOf(index, constants.NODES_PER_PAGE);
            _ = try page_ops.ensureNodePage(core, page);
            page_ops.nodeAt(core, .{ .index = index }).next_local_edge_id.store(1, .monotonic);

            if (core.node_count.cmpxchgWeak(index, index + 1, .acq_rel, .acquire) == null) {
                return types.NodeId{ .index = index };
            }
        }
    }

    pub fn nodeCount(self: *const Graph) usize {
        const core = self.tryBeginConstCall() orelse return 0;
        defer endCall(core);
        return core.publishedNodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        const core = self.tryBeginConstCall() orelse return 0;
        defer endCall(core);
        return core.edge_count.load(.acquire);
    }

    pub fn hasNode(self: *const Graph, id: types.NodeId) bool {
        const core = self.tryBeginConstCall() orelse return false;
        defer endCall(core);
        return node_validity.isNodeLive(core, id);
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

    pub fn allocGroupSpan(self: *Graph, count: u16) !u32 {
        return page_ops.allocGroupSpan(&self.graph, count);
    }

    pub fn freeGroup(self: *Graph, idx: u32) void {
        page_ops.freeGroup(&self.graph, idx);
    }

    pub fn freeGroupSpan(self: *Graph, first_idx: u32, count: u16) void {
        page_ops.freeGroupSpan(&self.graph, first_idx, count);
    }

    pub fn hasEdgeInAdj(self: *const Graph, adj: types.NodeAdj, target: u32) bool {
        return adjacency.hasEdgeInAdj(&self.graph, adj, target);
    }

    pub fn publishedNodeAdj(self: *const Graph, node: types.NodeId) !types.NodeAdj {
        const core = try self.beginConstCall();
        defer endCall(core);
        return adjacency.publishedNodeAdj(core, node);
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
        const core = try self.beginConstCall();
        defer endCall(core);
        return validate_mod.validate(core);
    }

    pub fn debugValidate(self: *const Graph, allocator: std.mem.Allocator) GraphError![]types.Violation {
        const core = try self.beginConstCall();
        defer endCall(core);
        return validate_mod.debugValidate(core, allocator);
    }

    // ── Query API ─────────────────────────────────────────────────────

    pub fn neighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        const core = try self.beginConstCall();
        defer endCall(core);
        return query.neighbors(core, node);
    }

    pub fn inNeighbors(self: *const Graph, node: types.NodeId) GraphError!query.NeighborIterator {
        const core = try self.beginConstCall();
        defer endCall(core);
        return query.inNeighbors(core, node);
    }

    pub fn outDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        const core = try self.beginConstCall();
        defer endCall(core);
        return query.outDegree(core, node);
    }

    pub fn inDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        const core = try self.beginConstCall();
        defer endCall(core);
        return query.inDegree(core, node);
    }

    pub fn outEdges(self: *const Graph, node: types.NodeId) GraphError!out_edge_iter.OutEdgeIterator {
        const core = try self.beginConstCall();
        defer endCall(core);
        if (!core.multigraph_enabled) return error.UnsupportedOperation;
        return out_edge_iter.outEdges(core, node);
    }

    pub fn beginReadSession(self: *const Graph) GraphError!ReadSession {
        const core = try self.beginConstCall();
        errdefer endCall(core);

        const reader_token = try rcu.readerEnter(core);
        return ReadSession.init(core, reader_token);
    }

    // ── Repair API ────────────────────────────────────────────────────

    pub fn repairNode(self: *Graph, node: types.NodeId) GraphError!void {
        const core = try self.beginMutCall();
        defer endCall(core);
        return repair.repairNode(core, node);
    }

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) GraphError!usize {
        const core = try self.beginMutCall();
        defer endCall(core);
        return repair.repairBudgeted(core, max_nodes);
    }

    pub fn flushRepairs(self: *Graph) GraphError!types.RepairFlushSummary {
        const core = try self.beginMutCall();
        defer endCall(core);
        return repair.flushRepairs(core);
    }

    pub fn debtStats(self: *const Graph) GraphError!types.DebtStats {
        const core = try self.beginConstCall();
        defer endCall(core);
        return stats_mod.debtStats(core);
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub fn addEdge(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        const core = try self.beginMutCall();
        defer endCall(core);
        return mutation.addEdge(core, source, destination, relation, flags);
    }

    pub fn addEdgeWithId(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!types.EdgeId {
        const core = try self.beginMutCall();
        defer endCall(core);
        if (!core.multigraph_enabled) return error.UnsupportedOperation;
        return mutation.addEdgeWithId(core, source, destination, relation, flags);
    }

    pub fn removeEdge(self: *Graph, source: types.NodeId, destination: types.NodeId) GraphError!bool {
        const core = try self.beginMutCall();
        defer endCall(core);
        return mutation.removeEdge(core, source, destination);
    }

    pub fn removeEdgeWithId(self: *Graph, source: types.NodeId, destination: types.NodeId, edge_id: types.EdgeId) GraphError!bool {
        const core = try self.beginMutCall();
        defer endCall(core);
        if (!core.multigraph_enabled) return error.UnsupportedOperation;
        return mutation.removeEdgeWithId(core, source, destination, edge_id);
    }

    pub fn removeNode(self: *Graph, node: types.NodeId) GraphError!types.NodeRemovalSummary {
        const core = try self.beginMutCall();
        defer endCall(core);
        return mutation.removeNode(core, node);
    }
};

pub const GraphBuilder = @import("internal/builder.zig").GraphBuilder;
