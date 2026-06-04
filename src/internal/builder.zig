//! Internal batch graph construction engine used by the public opaque
//! `GraphBuilder` wrapper and white-box tests.

const std = @import("std");
const constants = @import("../core/constants.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");
const graph_mod = @import("../graph.zig");

const Graph = graph_mod.Graph;
const GraphError = types.GraphError;

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

const FreezePlan = struct {
    fwd_degrees: []u32,
    rev_degrees: []u32,
    fwd_block_counts: []u16,
    rev_block_counts: []u16,
    total_fwd_blocks: u32 = 0,
    total_rev_blocks: u32 = 0,

    fn init(allocator: std.mem.Allocator, node_count: usize) !FreezePlan {
        const fwd_degrees = try allocator.alloc(u32, node_count);
        errdefer allocator.free(fwd_degrees);
        const rev_degrees = try allocator.alloc(u32, node_count);
        errdefer allocator.free(rev_degrees);
        const fwd_block_counts = try allocator.alloc(u16, node_count);
        errdefer allocator.free(fwd_block_counts);
        const rev_block_counts = try allocator.alloc(u16, node_count);
        errdefer allocator.free(rev_block_counts);

        @memset(fwd_degrees, 0);
        @memset(rev_degrees, 0);
        @memset(fwd_block_counts, 0);
        @memset(rev_block_counts, 0);

        return .{
            .fwd_degrees = fwd_degrees,
            .rev_degrees = rev_degrees,
            .fwd_block_counts = fwd_block_counts,
            .rev_block_counts = rev_block_counts,
        };
    }

    fn deinit(self: *FreezePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.fwd_degrees);
        allocator.free(self.rev_degrees);
        allocator.free(self.fwd_block_counts);
        allocator.free(self.rev_block_counts);
    }
};

pub const GraphBuilder = struct {
    graph: Graph,
    edges: std.ArrayList(BuilderEdge) = .empty,
    edge_keys: std.AutoHashMap(u64, void),
    frozen: bool = false,

    pub fn init(allocator: std.mem.Allocator) !GraphBuilder {
        var graph = try Graph.init(allocator);
        errdefer graph.deinit();
        return .{
            .graph = graph,
            .edge_keys = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn deinit(self: *GraphBuilder) void {
        const allocator = self.graph.graph.allocator;
        self.edges.deinit(allocator);
        self.edge_keys.deinit();
        if (!self.frozen) self.graph.deinit();
    }

    pub fn addNode(self: *GraphBuilder) !types.NodeId {
        if (self.frozen) return error.UnsupportedOperation;
        return self.graph.addNode();
    }

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
        if (blocks > std.math.maxInt(u16)) return error.BlockLimitReached;
        return @intCast(blocks);
    }

    fn buildFreezePlan(self: *GraphBuilder) !FreezePlan {
        const allocator = self.graph.graph.allocator;
        const node_count = self.graph.nodeCount();
        var plan = try FreezePlan.init(allocator, node_count);
        errdefer plan.deinit(allocator);

        for (self.edges.items) |edge| {
            plan.fwd_degrees[edge.source] += 1;
            plan.rev_degrees[edge.destination] += 1;
        }

        for (0..node_count) |node_index| {
            const fwd_block_count = try blockCountForEdgeCount(plan.fwd_degrees[node_index]);
            const rev_block_count = try blockCountForEdgeCount(plan.rev_degrees[node_index]);
            plan.fwd_block_counts[node_index] = fwd_block_count;
            plan.rev_block_counts[node_index] = rev_block_count;
            plan.total_fwd_blocks += fwd_block_count;
            plan.total_rev_blocks += rev_block_count;
        }

        return plan;
    }

    fn prepareBlockCapacity(self: *GraphBuilder, plan: *const FreezePlan) !struct { base_fwd: u32, base_rev: u32 } {
        const base_fwd = self.graph.graph.block_fwd_count;
        const base_rev = self.graph.graph.block_rev_count;

        const final_fwd_count = std.math.add(u32, base_fwd, plan.total_fwd_blocks) catch return error.OutOfMemory;
        const final_rev_count = std.math.add(u32, base_rev, plan.total_rev_blocks) catch return error.OutOfMemory;

        try page_ops.ensureBlockCapacity(&self.graph.graph, final_fwd_count, .fwd);
        try page_ops.ensureBlockCapacity(&self.graph.graph, final_rev_count, .rev);

        return .{ .base_fwd = base_fwd, .base_rev = base_rev };
    }

    fn publishForwardRun(self: *GraphBuilder, source_index: u32, run: []const BuilderEdge, first_block: u32, block_count: u16) void {
        if (run.len == 0) return;

        var edge_index: usize = 0;

        for (0..block_count) |block_offset| {
            const block_index = first_block + @as(u32, @intCast(block_offset));
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

    fn publishReverseRun(self: *GraphBuilder, destination_index: u32, run: []const BuilderEdge, first_block: u32, block_count: u16) void {
        if (run.len == 0) return;

        var edge_index: usize = 0;

        for (0..block_count) |block_offset| {
            const block_index = first_block + @as(u32, @intCast(block_offset));
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

    fn publishForwardAdjacencies(self: *GraphBuilder, plan: *const FreezePlan, base_fwd: u32) void {
        std.sort.heap(BuilderEdge, self.edges.items, {}, BuilderEdge.lessForward);

        var next_block_index = base_fwd;
        var start: usize = 0;
        while (start < self.edges.items.len) {
            const source = self.edges.items[start].source;
            var end = start + 1;
            while (end < self.edges.items.len and self.edges.items[end].source == source) : (end += 1) {}
            const block_count = plan.fwd_block_counts[source];
            self.publishForwardRun(source, self.edges.items[start..end], next_block_index, block_count);
            next_block_index += block_count;
            start = end;
        }

        std.debug.assert(next_block_index == base_fwd + plan.total_fwd_blocks);
    }

    fn publishReverseAdjacencies(self: *GraphBuilder, plan: *const FreezePlan, base_rev: u32) void {
        std.sort.heap(BuilderEdge, self.edges.items, {}, BuilderEdge.lessReverse);

        var next_block_index = base_rev;
        var start: usize = 0;
        while (start < self.edges.items.len) {
            const destination = self.edges.items[start].destination;
            var end = start + 1;
            while (end < self.edges.items.len and self.edges.items[end].destination == destination) : (end += 1) {}
            const block_count = plan.rev_block_counts[destination];
            self.publishReverseRun(destination, self.edges.items[start..end], next_block_index, block_count);
            next_block_index += block_count;
            start = end;
        }

        std.debug.assert(next_block_index == base_rev + plan.total_rev_blocks);
    }

    fn clearBuildStorage(self: *GraphBuilder) void {
        const allocator = self.graph.graph.allocator;
        self.edges.deinit(allocator);
        self.edges = .empty;
        self.edge_keys.deinit();
        self.edge_keys = std.AutoHashMap(u64, void).init(allocator);
    }

    fn publishExactDegrees(self: *GraphBuilder, plan: *const FreezePlan) void {
        for (0..self.graph.nodeCount()) |node_index| {
            const node_buffer = page_ops.nodeAt(&self.graph.graph, .{ .index = @intCast(node_index) });
            node_buffer.storePublishedMeta(.{
                .degree_fwd = @intCast(plan.fwd_degrees[node_index]),
                .degree_rev = @intCast(plan.rev_degrees[node_index]),
            });
        }
    }

    pub fn freeze(self: *GraphBuilder) !Graph {
        if (self.frozen) return error.UnsupportedOperation;

        var plan = try self.buildFreezePlan();
        defer plan.deinit(self.graph.graph.allocator);
        const reservation = try self.prepareBlockCapacity(&plan);

        self.resetPublishedAdjacencyBuffers();
        self.publishForwardAdjacencies(&plan, reservation.base_fwd);
        self.publishReverseAdjacencies(&plan, reservation.base_rev);
        self.graph.graph.block_fwd_count = reservation.base_fwd + plan.total_fwd_blocks;
        self.graph.graph.block_rev_count = reservation.base_rev + plan.total_rev_blocks;
        self.graph.graph.edge_count.store(@intCast(self.edges.items.len), .release);
        self.publishExactDegrees(&plan);

        const result = Graph{ .graph = self.graph.graph };
        self.clearBuildStorage();
        self.frozen = true;
        return result;
    }
};
