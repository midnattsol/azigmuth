//! Internal batch graph construction engine used by the public opaque
//! `GraphBuilder` wrapper and white-box tests.

const std = @import("std");
const constants = @import("../core/constants.zig");
const node_access = @import("../core/node_access.zig");
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
    insertion_order: u64,

    fn key(source: types.NodeId, destination: types.NodeId) u64 {
        return (@as(u64, source.index) << 32) | @as(u64, destination.index);
    }

    fn lessForward(_: void, lhs: BuilderEdge, rhs: BuilderEdge) bool {
        if (lhs.source != rhs.source) return lhs.source < rhs.source;
        if (lhs.destination != rhs.destination) return lhs.destination < rhs.destination;
        return lhs.insertion_order < rhs.insertion_order;
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

    fn initGraph(allocator: std.mem.Allocator, options: ?types.GraphOptions) !Graph {
        var graph = if (options) |graph_options|
            try Graph.initWithOptions(allocator, graph_options)
        else
            try Graph.init(allocator);
        errdefer graph.deinit();
        return graph;
    }

    fn setContiguousSide(side: *types.SideAdj, first_block: u32, block_count: u16) void {
        side.first_block = first_block;
        side.block_count = block_count;
        side.group_count = 0;
        side.first_group = 0;
    }

    pub fn init(allocator: std.mem.Allocator) !GraphBuilder {
        const graph = try initGraph(allocator, null);
        return .{
            .graph = graph,
            .edge_keys = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: types.GraphOptions) !GraphBuilder {
        const graph = try initGraph(allocator, options);
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

        if (!self.graph.graph.multigraph_enabled) {
            const key = BuilderEdge.key(source, destination);
            const entry = try self.edge_keys.getOrPut(key);
            if (entry.found_existing) return error.EdgeAlreadyExists;
            errdefer _ = self.edge_keys.remove(key);
        }

        try self.edges.append(self.graph.graph.allocator, .{
            .source = source.index,
            .destination = destination.index,
            .relation = relation,
            .flags = flags,
            .insertion_order = self.edges.items.len,
        });
    }

    fn resetPublishedAdjacencyBuffers(self: *GraphBuilder) void {
        for (0..self.graph.nodeCount()) |node_index| {
            const node = graph_mod.NodeId{ .index = @intCast(node_index) };
            const node_buffer = node_access.nodeAt(&self.graph.graph, node);
            node_access.resetPublishedSides(&self.graph.graph, node);
            page_ops.nodeHotAt(&self.graph.graph, .{ .index = @intCast(node_index) }).storeNextLocalEdgeId(1);
            node_buffer.next_local_edge_id.store(1, .monotonic);
            page_ops.nodeMetaAt(&self.graph.graph, .{ .index = @intCast(node_index) }).storePublishedMeta(.{});
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
        var next_edge_id: u32 = 1;

        for (0..block_count) |block_offset| {
            const block_index = first_block + @as(u32, @intCast(block_offset));
            const block = page_ops.edgeBlockAt(&self.graph.graph, block_index, .fwd);
            block.* = std.mem.zeroes(types.EdgeBlockFwd);

            const id_block = if (self.graph.graph.multigraph_enabled)
                page_ops.edgeBlockFwdIdsAt(&self.graph.graph, block_index)
            else
                null;
            if (self.graph.graph.multigraph_enabled) {
                id_block.?.* = std.mem.zeroes(types.EdgeBlockFwdIds);
            }

            const remaining = run.len - edge_index;
            const live = @min(remaining, 64);
            for (0..live) |slot| {
                const edge = run[edge_index + slot];
                block.destinations[slot] = edge.destination;
                block.relations[slot] = edge.relation;
                block.flags[slot] = edge.flags;
                if (id_block) |fwd_ids| {
                    fwd_ids.ids[slot] = next_edge_id;
                    next_edge_id += 1;
                }
            }
            block.mask = constants.denseMask(@intCast(live));
            edge_index += live;
        }

        const node = graph_mod.NodeId{ .index = source_index };
        const node_buffer = node_access.nodeAt(&self.graph.graph, node);
        if (self.graph.graph.multigraph_enabled) {
            page_ops.nodeHotAt(&self.graph.graph, .{ .index = source_index }).storeNextLocalEdgeId(next_edge_id);
            node_buffer.next_local_edge_id.store(next_edge_id, .monotonic);
        }
        var side_adj = std.mem.zeroes(types.SideAdj);
        setContiguousSide(&side_adj, first_block, block_count);
        node_access.setInitialPublishedFwdSide(&self.graph.graph, node, side_adj);
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

    fn publishReverseAdjacencies(self: *GraphBuilder, plan: *const FreezePlan, base_rev: u32) !void {
        const allocator = self.graph.graph.allocator;
        const node_count = self.graph.nodeCount();

        var rev_first_blocks = try allocator.alloc(u32, node_count);
        defer allocator.free(rev_first_blocks);
        var rev_positions = try allocator.alloc(u32, node_count);
        defer allocator.free(rev_positions);
        @memset(rev_positions, 0);

        var next_block_index = base_rev;
        for (0..node_count) |node_index| {
            rev_first_blocks[node_index] = next_block_index;
            const block_count = plan.rev_block_counts[node_index];
            if (block_count == 0) continue;

            for (0..block_count) |block_offset| {
                const block_index = next_block_index + @as(u32, @intCast(block_offset));
                page_ops.edgeBlockAt(&self.graph.graph, block_index, .rev).* = std.mem.zeroes(types.EdgeBlockRev);
            }

            const node = graph_mod.NodeId{ .index = @intCast(node_index) };
            var side_adj = std.mem.zeroes(types.SideAdj);
            setContiguousSide(&side_adj, next_block_index, block_count);
            node_access.setInitialPublishedRevSide(&self.graph.graph, node, side_adj);
            next_block_index += block_count;
        }

        for (self.edges.items) |edge| {
            const destination_index = edge.destination;
            const position = rev_positions[destination_index];
            rev_positions[destination_index] = position + 1;

            const block_index = rev_first_blocks[destination_index] + position / 64;
            const slot: usize = @intCast(position % 64);
            page_ops.edgeBlockAt(&self.graph.graph, block_index, .rev).sources[slot] = edge.source;
        }

        for (0..node_count) |node_index| {
            const degree = plan.rev_degrees[node_index];
            const block_count = plan.rev_block_counts[node_index];
            if (block_count == 0) continue;

            const first_block = rev_first_blocks[node_index];
            var remaining = degree;
            for (0..block_count) |block_offset| {
                const live = @min(remaining, 64);
                const block_index = first_block + @as(u32, @intCast(block_offset));
                page_ops.edgeBlockAt(&self.graph.graph, block_index, .rev).mask = constants.denseMask(@intCast(live));
                remaining -= live;
            }
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
            const node_buffer = node_access.nodeAt(&self.graph.graph, .{ .index = @intCast(node_index) });
            const meta = (types.PublishedMeta{}).withFwdDegree(@intCast(plan.fwd_degrees[node_index])).withRevDegree(@intCast(plan.rev_degrees[node_index]));
            node_access.setPublishedDegrees(&self.graph.graph, .{ .index = @intCast(node_index) }, meta, @intCast(plan.fwd_degrees[node_index]), @intCast(plan.rev_degrees[node_index]));
            page_ops.nodeMetaAt(&self.graph.graph, .{ .index = @intCast(node_index) }).storePublishedMeta(meta);
            node_buffer.storePublishedMeta(meta);
        }
    }

    pub fn freeze(self: *GraphBuilder) !Graph {
        if (self.frozen) return error.UnsupportedOperation;

        var plan = try self.buildFreezePlan();
        defer plan.deinit(self.graph.graph.allocator);
        const reservation = try self.prepareBlockCapacity(&plan);

        self.resetPublishedAdjacencyBuffers();
        self.publishForwardAdjacencies(&plan, reservation.base_fwd);
        try self.publishReverseAdjacencies(&plan, reservation.base_rev);
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
