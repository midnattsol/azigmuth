//! Batch graph construction — build a graph from sorted edge batches, then freeze into the CSR representation.

const std = @import("std");
const constants = @import("../core/constants.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const graph_mod = @import("../graph.zig");

const Graph = graph_mod.Graph;
const GraphError = types.GraphError;

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
