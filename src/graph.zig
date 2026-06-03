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
const node_validity = @import("node_validity.zig");

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
        if (core.active_writers.load(.acquire) != 0) return true;
        if (core.reader_epoch_overflow.load(.acquire) != 0) return true;
        for (&core.reader_epochs) |*slot| {
            if (slot.load(.acquire) != 0) return true;
        }
        return false;
    }

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
        };
        try state_value.retired_blocks_fwd.ensureTotalCapacity(allocator, constants.MAX_TRACKED_RETIRED_BLOCKS);
        errdefer state_value.retired_blocks_fwd.deinit(allocator);
        try state_value.retired_blocks_rev.ensureTotalCapacity(allocator, constants.MAX_TRACKED_RETIRED_BLOCKS);
        errdefer state_value.retired_blocks_rev.deinit(allocator);

        state_value.node_pages_pages[0].store(@intFromPtr(first_page.ptr), .release);
        state_value.node_pages.append(allocator, first_page) catch {};

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

    pub fn deinitChecked(self: *Graph) DeinitError!void {
        if (hasActiveReadersOrWriters(&self.graph)) return error.GraphBusy;
        self.deinit();
    }

    // ── Node API ──────────────────────────────────────────────────────

    pub fn addNode(self: *Graph) !types.NodeId {
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
        return self.graph.publishedNodeCount();
    }

    pub fn edgeCount(self: *const Graph) u64 {
        return self.graph.edge_count.load(.acquire);
    }

    pub fn hasNode(self: *const Graph, id: types.NodeId) bool {
        return node_validity.isNodeLive(&self.graph, id);
    }

    // ── Paged storage access ──────────────────────────────────────────

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

    pub fn appendGroupToAdj(self: *Graph, adj: *types.NodeAdj, new_block: u32, comptime dir: adjacency.AdjSide) !void {
        return adjacency.appendGroupToAdj(&self.graph, adj, new_block, dir);
    }

    pub fn tailBlockIndex(self: *Graph, adj: *const types.NodeAdj, comptime dir: adjacency.AdjSide) ?u32 {
        return adjacency.tailBlockIndex(&self.graph, adj, dir);
    }

    pub fn removeTailFromAdj(self: *Graph, adj: *types.NodeAdj, comptime dir: adjacency.AdjSide) void {
        adjacency.removeTailFromAdj(&self.graph, adj, dir);
    }

    pub fn hasEdgeInAdj(self: *const Graph, adj: types.NodeAdj, target: u32) bool {
        return adjacency.hasEdgeInAdj(&self.graph, adj, target);
    }

    pub fn publishedNodeAdj(self: *const Graph, node: types.NodeId) !types.NodeAdj {
        return adjacency.publishedNodeAdj(&self.graph, node);
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

    pub fn repairBudgeted(self: *Graph, max_nodes: usize) GraphError!usize {
        return repair.repairBudgeted(&self.graph, max_nodes);
    }

    // ── Mutation ──────────────────────────────────────────────────────

    pub fn addEdge(self: *Graph, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        return mutation.addEdge(&self.graph, source, destination, relation, flags);
    }

    pub fn removeEdge(self: *Graph, source: types.NodeId, destination: types.NodeId) GraphError!bool {
        return mutation.removeEdge(&self.graph, source, destination);
    }

    pub fn removeNode(self: *Graph, node: types.NodeId) GraphError!void {
        return mutation.removeNode(&self.graph, node);
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
/// must NOT be used again; `deinit()` only releases builder scratch storage.
const BuilderEdge = struct {
    source: u32,
    destination: u32,
    relation: u16,
    flags: u16,

    fn key(source: types.NodeId, destination: types.NodeId) u64 {
        return (@as(u64, source.index) << 32) | @as(u64, destination.index);
    }

    fn lessForward(_: void, lhs: BuilderEdge, rhs: BuilderEdge) bool {
        if (lhs.source != rhs.source) return lhs.source < rhs.source;
        return lhs.destination < rhs.destination;
    }

    fn lessReverse(_: void, lhs: BuilderEdge, rhs: BuilderEdge) bool {
        if (lhs.destination != rhs.destination) return lhs.destination < rhs.destination;
        return lhs.source < rhs.source;
    }
};

pub const GraphBuilder = struct {
    graph: Graph,
    edges: std.ArrayList(BuilderEdge) = .empty,
    edge_keys: std.AutoHashMap(u64, void),
    frozen: bool = false,

    /// Creates a new builder backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) !GraphBuilder {
        var graph = try Graph.init(allocator);
        errdefer graph.deinit();
        return .{
            .graph = graph,
            .edge_keys = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    /// Frees builder scratch resources and, if not frozen, the graph itself.
    pub fn deinit(self: *GraphBuilder) void {
        const allocator = self.graph.graph.allocator;
        self.edges.deinit(allocator);
        self.edge_keys.deinit();
        if (!self.frozen) self.graph.deinit();
    }

    /// Allocates a new node and returns its `NodeId`.
    pub fn addNode(self: *GraphBuilder) !types.NodeId {
        if (self.frozen) return error.UnsupportedOperation;
        return self.graph.addNode();
    }

    /// Adds a directed edge `source → destination` with the given relation
    /// label and edge flags. Returns `error.EdgeAlreadyExists` if an identical
    /// edge already exists in the build graph.
    pub fn addEdge(self: *GraphBuilder, source: types.NodeId, destination: types.NodeId, relation: u16, flags: u16) GraphError!void {
        if (self.frozen) return error.UnsupportedOperation;
        if (!self.graph.hasNode(source) or !self.graph.hasNode(destination)) return error.InvalidNode;

        const key = BuilderEdge.key(source, destination);
        const entry = try self.edge_keys.getOrPut(key);
        if (entry.found_existing) return error.EdgeAlreadyExists;
        errdefer _ = self.edge_keys.remove(key);

        try self.edges.append(self.graph.graph.allocator, .{
            .source = source.index,
            .destination = destination.index,
            .relation = relation,
            .flags = flags,
        });
    }

    fn resetPublishedAdjacencyBuffers(self: *GraphBuilder) void {
        for (0..self.graph.nodeCount()) |node_index| {
            const node_buffer = page_ops.nodeAt(&self.graph.graph, .{ .index = @intCast(node_index) });
            node_buffer.fwd_buffers[0] = std.mem.zeroes(types.SideAdj);
            node_buffer.fwd_buffers[1] = std.mem.zeroes(types.SideAdj);
            node_buffer.rev_buffers[0] = std.mem.zeroes(types.SideAdj);
            node_buffer.rev_buffers[1] = std.mem.zeroes(types.SideAdj);
            node_buffer.storePublishedMeta(.{});
        }
    }

    fn blockCountForEdgeCount(edge_count: usize) !u16 {
        const blocks = edge_count / 64 + @intFromBool(edge_count % 64 != 0);
        if (blocks > std.math.maxInt(u16)) return error.OutOfMemory;
        return @intCast(blocks);
    }

    fn publishForwardRun(self: *GraphBuilder, source_index: u32, run: []const BuilderEdge) !void {
        if (run.len == 0) return;

        const block_count = try blockCountForEdgeCount(run.len);
        var first_block: u32 = 0;
        var edge_index: usize = 0;

        for (0..block_count) |block_offset| {
            const block_index = try page_ops.allocBlock(&self.graph.graph, .fwd);
            if (block_offset == 0) first_block = block_index;
            const block = page_ops.edgeBlockAt(&self.graph.graph, block_index, .fwd);
            block.* = std.mem.zeroes(types.EdgeBlockFwd);

            const remaining = run.len - edge_index;
            const live = @min(remaining, 64);
            for (0..live) |slot| {
                const edge = run[edge_index + slot];
                block.edges[slot] = .{
                    .destination = edge.destination,
                    .relation = edge.relation,
                    .flags = @bitCast(edge.flags),
                };
            }
            block.mask = constants.denseMask(@intCast(live));
            edge_index += live;
        }

        const node_buffer = page_ops.nodeAt(&self.graph.graph, .{ .index = source_index });
        node_buffer.fwd_buffers[0].first_block = first_block;
        node_buffer.fwd_buffers[0].block_count = block_count;
        node_buffer.fwd_buffers[0].group_count = 0;
        node_buffer.fwd_buffers[0].first_group = 0;
    }

    fn publishReverseRun(self: *GraphBuilder, destination_index: u32, run: []const BuilderEdge) !void {
        if (run.len == 0) return;

        const block_count = try blockCountForEdgeCount(run.len);
        var first_block: u32 = 0;
        var edge_index: usize = 0;

        for (0..block_count) |block_offset| {
            const block_index = try page_ops.allocBlock(&self.graph.graph, .rev);
            if (block_offset == 0) first_block = block_index;
            const block = page_ops.edgeBlockAt(&self.graph.graph, block_index, .rev);
            block.* = std.mem.zeroes(types.EdgeBlockRev);

            const remaining = run.len - edge_index;
            const live = @min(remaining, 64);
            for (0..live) |slot| {
                block.sources[slot] = run[edge_index + slot].source;
            }
            block.mask = constants.denseMask(@intCast(live));
            edge_index += live;
        }

        const node_buffer = page_ops.nodeAt(&self.graph.graph, .{ .index = destination_index });
        node_buffer.rev_buffers[0].first_block = first_block;
        node_buffer.rev_buffers[0].block_count = block_count;
        node_buffer.rev_buffers[0].group_count = 0;
        node_buffer.rev_buffers[0].first_group = 0;
    }

    fn publishForwardAdjacencies(self: *GraphBuilder) !void {
        std.sort.heap(BuilderEdge, self.edges.items, {}, BuilderEdge.lessForward);

        var start: usize = 0;
        while (start < self.edges.items.len) {
            const source = self.edges.items[start].source;
            var end = start + 1;
            while (end < self.edges.items.len and self.edges.items[end].source == source) : (end += 1) {}
            try self.publishForwardRun(source, self.edges.items[start..end]);
            start = end;
        }
    }

    fn publishReverseAdjacencies(self: *GraphBuilder) !void {
        std.sort.heap(BuilderEdge, self.edges.items, {}, BuilderEdge.lessReverse);

        var start: usize = 0;
        while (start < self.edges.items.len) {
            const destination = self.edges.items[start].destination;
            var end = start + 1;
            while (end < self.edges.items.len and self.edges.items[end].destination == destination) : (end += 1) {}
            try self.publishReverseRun(destination, self.edges.items[start..end]);
            start = end;
        }
    }

    fn clearBuildStorage(self: *GraphBuilder) void {
        const allocator = self.graph.graph.allocator;
        self.edges.deinit(allocator);
        self.edges = .empty;
        self.edge_keys.deinit();
        self.edge_keys = std.AutoHashMap(u64, void).init(allocator);
    }

    fn publishExactDegrees(self: *GraphBuilder) void {
        for (0..self.graph.nodeCount()) |node_index| {
            const node_buffer = page_ops.nodeAt(&self.graph.graph, .{ .index = @intCast(node_index) });
            const adj = node_buffer.publishedAdj();

            var fwd: u22 = 0;
            if (adj.block_count_fwd > 0) {
                if (adj.group_count_fwd == 0) {
                    const end = adj.first_block_fwd + adj.block_count_fwd;
                    for (adj.first_block_fwd..end) |block_index| {
                        fwd += @as(u22, @intCast(@popCount(page_ops.edgeBlockAtConst(&self.graph.graph, @intCast(block_index), .fwd).mask)));
                    }
                } else {
                    var group_idx = adj.first_group_fwd;
                    while (group_idx != constants.END_OF_CHAIN) {
                        const group = page_ops.groupAtConst(&self.graph.graph, group_idx);
                        for (group.start..group.start + group.count) |block_index| {
                            fwd += @as(u22, @intCast(@popCount(page_ops.edgeBlockAtConst(&self.graph.graph, @intCast(block_index), .fwd).mask)));
                        }
                        group_idx = group.next;
                    }
                }
            }

            var rev: u22 = 0;
            if (adj.block_count_rev > 0) {
                if (adj.group_count_rev == 0) {
                    const end = adj.first_block_rev + adj.block_count_rev;
                    for (adj.first_block_rev..end) |block_index| {
                        rev += @as(u22, @intCast(@popCount(page_ops.edgeBlockAtConst(&self.graph.graph, @intCast(block_index), .rev).mask)));
                    }
                } else {
                    var group_idx = adj.first_group_rev;
                    while (group_idx != constants.END_OF_CHAIN) {
                        const group = page_ops.groupAtConst(&self.graph.graph, group_idx);
                        for (group.start..group.start + group.count) |block_index| {
                            rev += @as(u22, @intCast(@popCount(page_ops.edgeBlockAtConst(&self.graph.graph, @intCast(block_index), .rev).mask)));
                        }
                        group_idx = group.next;
                    }
                }
            }

            var meta = node_buffer.loadPublishedMeta();
            meta.degree_fwd = fwd;
            meta.degree_rev = rev;
            node_buffer.storePublishedMeta(meta);
        }
    }

    /// Transfers ownership of the constructed graph to the caller.
    /// The caller is responsible for calling `graph.deinit()` on the returned
    /// value. The builder becomes inert after this call.
    pub fn freeze(self: *GraphBuilder) !Graph {
        if (self.frozen) return error.UnsupportedOperation;

        self.resetPublishedAdjacencyBuffers();
        try self.publishForwardAdjacencies();
        try self.publishReverseAdjacencies();
        self.graph.graph.edge_count.store(@intCast(self.edges.items.len), .release);
        self.publishExactDegrees();

        const result = Graph{ .graph = self.graph.graph };
        self.clearBuildStorage();
        self.frozen = true;
        return result;
    }
};
