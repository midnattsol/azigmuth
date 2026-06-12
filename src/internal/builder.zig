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
        for (0..self.graph.nodeCount()) |node_idx| {
            const node = graph_mod.NodeId{ .index = @intCast(node_idx) };
            node_access.resetPublishedSides(&self.graph.graph, node);
            page_ops.nodeHotAt(&self.graph.graph, .{ .index = @intCast(node_idx) }).storeNextLocalEdgeId(1);
            page_ops.nodeMetaAt(&self.graph.graph, .{ .index = @intCast(node_idx) }).storePublishedMeta(.{});
        }
    }

    fn blockCountForEdgeCount(edge_count: usize) !u16 {
        const blocks = edge_count / constants.EDGES_PER_BLOCK + @intFromBool(edge_count % constants.EDGES_PER_BLOCK != 0);
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

        for (0..node_count) |node_idx| {
            const fwd_block_count = try blockCountForEdgeCount(plan.fwd_degrees[node_idx]);
            const rev_block_count = try blockCountForEdgeCount(plan.rev_degrees[node_idx]);
            plan.fwd_block_counts[node_idx] = fwd_block_count;
            plan.rev_block_counts[node_idx] = rev_block_count;
            plan.total_fwd_blocks += fwd_block_count;
            plan.total_rev_blocks += rev_block_count;
        }

        return plan;
    }

    fn prepareBlockCapacity(self: *GraphBuilder, plan: *const FreezePlan) !struct { base_fwd: u32, base_rev: u32 } {
        const base_fwd = self.graph.graph.loadBlockFwdCount();
        const base_rev = self.graph.graph.loadBlockRevCount();

        const final_fwd_count = std.math.add(u32, base_fwd, plan.total_fwd_blocks) catch return error.OutOfMemory;
        const final_rev_count = std.math.add(u32, base_rev, plan.total_rev_blocks) catch return error.OutOfMemory;

        try page_ops.ensureBlockCapacity(&self.graph.graph, final_fwd_count, .fwd);
        try page_ops.ensureBlockCapacity(&self.graph.graph, final_rev_count, .rev);
        if (self.graph.graph.edge_properties_enabled) {
            const final_rows = std.math.add(u32, self.graph.graph.loadPropRowCount(), std.math.cast(u32, self.edges.items.len) orelse return error.OutOfMemory) catch return error.OutOfMemory;
            try page_ops.ensurePropRowCapacity(&self.graph.graph, final_rows);
        }

        return .{ .base_fwd = base_fwd, .base_rev = base_rev };
    }

    fn publishForwardRun(self: *GraphBuilder, source_idx: u32, run: []const BuilderEdge, first_block: u32, block_count: u16, next_prop_row: *u32) void {
        if (run.len == 0) return;

        var edge_idx: usize = 0;
        var next_edge_id: u32 = 1;

        for (0..block_count) |block_offset| {
            const block_idx = first_block + @as(u32, @intCast(block_offset));
            const block = page_ops.edgeBlockAt(&self.graph.graph, block_idx, .fwd);
            block.* = std.mem.zeroes(types.EdgeBlockFwd);

            const id_block = if (self.graph.graph.multigraph_enabled)
                page_ops.edgeBlockFwdIdsAt(&self.graph.graph, block_idx)
            else
                null;
            if (self.graph.graph.multigraph_enabled) {
                id_block.?.* = std.mem.zeroes(types.EdgeBlockFwdIds);
            }
            const prop_block = if (self.graph.graph.edge_properties_enabled)
                page_ops.edgeBlockFwdPropsAt(&self.graph.graph, block_idx)
            else
                null;
            if (prop_block) |fwd_props| fwd_props.* = std.mem.zeroes(types.EdgeBlockFwdProps);

            const remaining = run.len - edge_idx;
            const live = @min(remaining, constants.EDGES_PER_BLOCK);
            for (0..live) |slot| {
                const edge = run[edge_idx + slot];
                block.destinations[slot] = edge.destination;
                block.relations[slot] = edge.relation;
                block.flags[slot] = edge.flags;
                if (id_block) |fwd_ids| {
                    fwd_ids.ids[slot] = next_edge_id;
                    next_edge_id += 1;
                }
                if (prop_block) |fwd_props| {
                    fwd_props.rows[slot] = next_prop_row.*;
                    next_prop_row.* += 1;
                }
            }
            page_ops.setBlockLiveCount(&self.graph.graph, block_idx, .fwd, @intCast(live));
            edge_idx += live;
        }

        const node = graph_mod.NodeId{ .index = source_idx };
        if (self.graph.graph.multigraph_enabled) {
            page_ops.nodeHotAt(&self.graph.graph, .{ .index = source_idx }).storeNextLocalEdgeId(next_edge_id);
        }
        var side_adj = std.mem.zeroes(types.SideAdj);
        setContiguousSide(&side_adj, first_block, block_count);
        node_access.setInitialPublishedFwdSide(&self.graph.graph, node, side_adj);
    }

    fn publishForwardAdjacencies(self: *GraphBuilder, plan: *const FreezePlan, base_fwd: u32) void {
        // pdq is safe here: insertion_order makes lessForward a total order,
        // so the unstable sort is deterministic.
        std.sort.pdq(BuilderEdge, self.edges.items, {}, BuilderEdge.lessForward);

        var next_prop_row: u32 = self.graph.graph.loadPropRowCount();
        var next_block_idx = base_fwd;
        var start: usize = 0;
        while (start < self.edges.items.len) {
            const source = self.edges.items[start].source;
            var end = start + 1;
            while (end < self.edges.items.len and self.edges.items[end].source == source) : (end += 1) {}
            const block_count = plan.fwd_block_counts[source];
            self.publishForwardRun(source, self.edges.items[start..end], next_block_idx, block_count, &next_prop_row);
            next_block_idx += block_count;
            start = end;
        }
        if (self.graph.graph.edge_properties_enabled) {
            @atomicStore(u32, &self.graph.graph.prop_row_count, next_prop_row, .release);
        }

        std.debug.assert(next_block_idx == base_fwd + plan.total_fwd_blocks);
    }

    fn publishReverseAdjacencies(self: *GraphBuilder, plan: *const FreezePlan, base_rev: u32) !void {
        const allocator = self.graph.graph.allocator;
        const node_count = self.graph.nodeCount();

        var rev_first_blocks = try allocator.alloc(u32, node_count);
        defer allocator.free(rev_first_blocks);
        var rev_positions = try allocator.alloc(u32, node_count);
        defer allocator.free(rev_positions);
        @memset(rev_positions, 0);

        var next_block_idx = base_rev;
        for (0..node_count) |node_idx| {
            rev_first_blocks[node_idx] = next_block_idx;
            const block_count = plan.rev_block_counts[node_idx];
            if (block_count == 0) continue;

            for (0..block_count) |block_offset| {
                const block_idx = next_block_idx + @as(u32, @intCast(block_offset));
                page_ops.edgeBlockAt(&self.graph.graph, block_idx, .rev).* = std.mem.zeroes(types.EdgeBlockRev);
            }

            const node = graph_mod.NodeId{ .index = @intCast(node_idx) };
            var side_adj = std.mem.zeroes(types.SideAdj);
            setContiguousSide(&side_adj, next_block_idx, block_count);
            node_access.setInitialPublishedRevSide(&self.graph.graph, node, side_adj);
            next_block_idx += block_count;
        }

        for (self.edges.items) |edge| {
            const destination_idx = edge.destination;
            const position = rev_positions[destination_idx];
            rev_positions[destination_idx] = position + 1;

            const block_idx = rev_first_blocks[destination_idx] + position / constants.EDGES_PER_BLOCK;
            const slot: usize = @intCast(position % constants.EDGES_PER_BLOCK);
            page_ops.edgeBlockAt(&self.graph.graph, block_idx, .rev).sources[slot] = edge.source;
        }

        for (0..node_count) |node_idx| {
            const degree = plan.rev_degrees[node_idx];
            const block_count = plan.rev_block_counts[node_idx];
            if (block_count == 0) continue;

            const first_block = rev_first_blocks[node_idx];
            var remaining = degree;
            for (0..block_count) |block_offset| {
                const live = @min(remaining, constants.EDGES_PER_BLOCK);
                const block_idx = first_block + @as(u32, @intCast(block_offset));
                page_ops.setBlockLiveCount(&self.graph.graph, block_idx, .rev, @intCast(live));
                remaining -= live;
            }
        }

        std.debug.assert(next_block_idx == base_rev + plan.total_rev_blocks);
    }

    fn clearBuildStorage(self: *GraphBuilder) void {
        const allocator = self.graph.graph.allocator;
        self.edges.deinit(allocator);
        self.edges = .empty;
        self.edge_keys.deinit();
        self.edge_keys = std.AutoHashMap(u64, void).init(allocator);
    }

    fn publishExactDegrees(self: *GraphBuilder, plan: *const FreezePlan) void {
        for (0..self.graph.nodeCount()) |node_idx| {
            const meta = (types.PublishedMeta{}).withFwdDegree(@intCast(plan.fwd_degrees[node_idx])).withRevDegree(@intCast(plan.rev_degrees[node_idx]));
            node_access.setPublishedDegrees(&self.graph.graph, .{ .index = @intCast(node_idx) }, meta, @intCast(plan.fwd_degrees[node_idx]), @intCast(plan.rev_degrees[node_idx]));
            page_ops.nodeMetaAt(&self.graph.graph, .{ .index = @intCast(node_idx) }).storePublishedMeta(meta);
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
        @atomicStore(u32, &self.graph.graph.block_fwd_count, reservation.base_fwd + plan.total_fwd_blocks, .release);
        @atomicStore(u32, &self.graph.graph.block_rev_count, reservation.base_rev + plan.total_rev_blocks, .release);
        self.graph.graph.edge_count.store(@intCast(self.edges.items.len), .release);
        self.publishExactDegrees(&plan);

        const result = Graph{ .graph = self.graph.graph };
        self.clearBuildStorage();
        self.frozen = true;
        return result;
    }
};
