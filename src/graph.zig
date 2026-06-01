const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");

// ── Implementation modules ───────────────────────────────────────────────
const page_ops = @import("page_ops.zig");
const adjacency = @import("adjacency.zig");
const rcu = @import("rcu.zig");
const mutation = @import("mutation.zig");
const query = @import("query.zig");
const repair = @import("repair.zig");
const validate_mod = @import("validate.zig");

// ── Re-exports ───────────────────────────────────────────────────────────
pub const NodeId = types.NodeId;
pub const GraphError = types.GraphError;
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

    pub fn init(allocator: std.mem.Allocator) !Graph {
        const first_page = try allocator.alloc(types.NodeBuffer, constants.NODES_PER_PAGE);
        errdefer allocator.free(first_page);
        @memset(first_page, std.mem.zeroes(types.NodeBuffer));

        var state_value = graph_core.GraphCore{
            .allocator = allocator,
            .node_pages = .empty,
            .edge_blocks_fwd = .empty,
            .edge_blocks_rev = .empty,
            .edge_block_groups = .empty,
            .free_blocks_fwd = .empty,
            .free_blocks_rev = .empty,
            .free_groups = .empty,
            .retired_blocks_fwd = .empty,
            .retired_blocks_rev = .empty,
            .repair_fwd = .empty,
            .repair_rev = .empty,
            .node_count = 0,
        };
        try state_value.retired_blocks_fwd.ensureTotalCapacity(allocator, constants.MAX_TRACKED_RETIRED_BLOCKS);
        errdefer state_value.retired_blocks_fwd.deinit(allocator);
        try state_value.retired_blocks_rev.ensureTotalCapacity(allocator, constants.MAX_TRACKED_RETIRED_BLOCKS);
        errdefer state_value.retired_blocks_rev.deinit(allocator);

        try state_value.node_pages.append(allocator, first_page);

        return .{ .graph = state_value };
    }

    pub fn deinit(self: *Graph) void {
        const alloc = self.graph.allocator;
        for (self.graph.node_pages.items) |page| alloc.free(page);
        freeAtomicPages(types.EdgeBlockFwd, alloc, self.graph.edge_blocks_fwd_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockRev, alloc, self.graph.edge_blocks_rev_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.EdgeBlockGroup, alloc, self.graph.edge_block_group_pages[0..], constants.EDGE_GROUPS_PER_PAGE);
        freeAtomicPages(types.BlockMeta, alloc, self.graph.edge_blocks_fwd_meta_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);
        freeAtomicPages(types.BlockMeta, alloc, self.graph.edge_blocks_rev_meta_pages[0..], constants.EDGE_BLOCKS_PER_PAGE);

        self.graph.node_pages.deinit(alloc);
        self.graph.edge_blocks_fwd.deinit(alloc);
        self.graph.edge_blocks_rev.deinit(alloc);
        self.graph.edge_block_groups.deinit(alloc);

        self.graph.free_blocks_fwd.deinit(alloc);
        self.graph.free_blocks_rev.deinit(alloc);
        self.graph.free_groups.deinit(alloc);
        self.graph.retired_blocks_fwd.deinit(alloc);
        self.graph.retired_blocks_rev.deinit(alloc);
        self.graph.repair_fwd.deinit(alloc);
        self.graph.repair_rev.deinit(alloc);
    }

    // ── Node API ──────────────────────────────────────────────────────

    pub fn addNode(self: *Graph) !types.NodeId {
        const index = self.graph.node_count;
        const page = page_ops.pageOf(index, constants.NODES_PER_PAGE);

        if (page == self.graph.node_pages.items.len) {
            const new_page = try self.graph.allocator.alloc(types.NodeBuffer, constants.NODES_PER_PAGE);
            @memset(new_page, std.mem.zeroes(types.NodeBuffer));
            try self.graph.node_pages.append(self.graph.allocator, new_page);
        }

        self.graph.node_count += 1;
        return types.NodeId{ .index = index };
    }

    pub fn nodeCount(self: *const Graph) usize {
        return self.graph.node_count;
    }

    pub fn edgeCount(self: *const Graph) u64 {
        return self.graph.edge_count.load(.acquire);
    }

    pub fn hasNode(self: *const Graph, id: types.NodeId) bool {
        return id.index < self.graph.node_count;
    }

    // ── Paged storage access ──────────────────────────────────────────

    pub fn nodeAt(self: *Graph, node: types.NodeId) !*types.NodeBuffer {
        if (!self.hasNode(node)) return error.InvalidNode;
        return page_ops.nodeAt(&self.graph, node);
    }

    pub fn nodeAtConst(self: *const Graph, node: types.NodeId) !*const types.NodeBuffer {
        if (!self.hasNode(node)) return error.InvalidNode;
        return page_ops.nodeAtConst(&self.graph, node);
    }

    // ── Block allocation ──────────────────────────────────────────────

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

    // ── Adjacency methods ─────────────────────────────────────────────

    pub fn appendGroupToAdj(self: *Graph, adj: *types.NodeAdj, new_block: u32, comptime dir: enum { fwd, rev }) !void {
        return adjacency.appendGroupToAdj(&self.graph, adj, new_block, dir);
    }

    pub fn tailBlockIndex(self: *Graph, adj: *const types.NodeAdj, comptime dir: enum { fwd, rev }) u32 {
        return adjacency.tailBlockIndex(&self.graph, adj, dir);
    }

    pub fn removeTailFromAdj(self: *Graph, adj: *types.NodeAdj, comptime dir: enum { fwd, rev }) void {
        adjacency.removeTailFromAdj(&self.graph, adj, dir);
    }

    pub fn hasEdgeInAdj(self: *const Graph, adj: types.NodeAdj, target: u32) bool {
        return adjacency.hasEdgeInAdj(&self.graph, adj, target);
    }

    pub fn publishedNodeAdj(self: *const Graph, node: types.NodeId) !types.NodeAdj {
        return adjacency.publishedNodeAdj(&self.graph, node);
    }

    pub fn prepareStagingAdj(self: *Graph, node: types.NodeId) !*types.NodeAdj {
        return adjacency.prepareStagingAdj(&self.graph, node);
    }

    pub fn publishStagingAdj(self: *Graph, node: types.NodeId) !void {
        return adjacency.publishStagingAdj(&self.graph, node);
    }

    // ── RCU methods ───────────────────────────────────────────────────

    pub const ReaderToken = rcu.ReaderToken;

    pub fn readerEnter(self: *Graph) ReaderToken {
        return rcu.readerEnter(&self.graph);
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
        return query.outDegree(&self.graph, node);
    }

    pub fn inDegree(self: *const Graph, node: types.NodeId) GraphError!usize {
        return query.inDegree(&self.graph, node);
    }

    // ── Repair API ────────────────────────────────────────────────────

    pub fn repairNode(self: *Graph, node: types.NodeId) GraphError!void {
        return repair.repairNode(&self.graph, node);
    }

    pub fn repairBudgeted(self: *Graph, max_steps: usize) GraphError!usize {
        return repair.repairBudgeted(&self.graph, max_steps);
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub fn addEdge(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        return mutation.addEdge(&self.graph, source, destination, relation, flags);
    }

    pub fn removeEdge(self: *Graph, source: types.NodeId, destination: types.NodeId) GraphError!bool {
        return mutation.removeEdge(&self.graph, source, destination);
    }

    pub fn removeNode(self: *Graph, node: types.NodeId) GraphError!void {
        if (!self.hasNode(node)) return error.InvalidNode;
        return error.UnsupportedOperation;
    }
};

// ── Batch construction ────────────────────────────────────────────────

/// Builds a Graph from dynamic node/edge additions, then `freeze()`s it
/// into the read-optimized CSR representation.
///
/// Each node receives a monotonic `NodeId`. Edges are added one at a time
/// and validated eagerly (duplicate edges are rejected).
///
/// Call `freeze()` to obtain the final `Graph`. After freezing, the builder
/// must NOT be used again; calling `deinit()` on a frozen builder is a no-op.
pub const GraphBuilder = struct {
    graph: Graph,
    frozen: bool = false,

    /// Creates a new builder backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) !GraphBuilder {
        return .{ .graph = try Graph.init(allocator) };
    }

    /// Frees resources if the builder was not frozen.
    pub fn deinit(self: *GraphBuilder) void {
        if (!self.frozen) self.graph.deinit();
    }

    /// Allocates a new node and returns its `NodeId`.
    pub fn addNode(self: *GraphBuilder) !types.NodeId {
        return self.graph.addNode();
    }

    /// Adds a directed edge `source → destination` with the given relation
    /// label and edge flags. Returns `error.EdgeAlreadyExists` if an identical
    /// edge already exists in the build graph.
    pub fn addEdge(self: *GraphBuilder, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        return self.graph.addEdge(source, destination, relation, flags);
    }

    /// Transfers ownership of the constructed graph to the caller.
    /// The caller is responsible for calling `graph.deinit()` on the returned
    /// value. The builder becomes inert after this call.
    pub fn freeze(self: *GraphBuilder) !Graph {
        self.frozen = true;
        for (0..self.graph.nodeCount()) |node_index| {
            try self.graph.repairNode(.{ .index = @intCast(node_index) });
        }
        return .{ .graph = self.graph.graph };
    }
};
