const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const adjacency = @import("../adjacency.zig");
const page_ops = @import("../storage/page_ops.zig");

pub const MutationScratch = struct {
    fwd_blocks: std.ArrayList(u32) = .empty,
    rev_blocks: std.ArrayList(u32) = .empty,
    groups: std.ArrayList(u32) = .empty,
    active: bool = true,

    pub fn allocBlock(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
        const block = try page_ops.allocBlock(graph, side);
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };
        list.append(graph.allocator, block) catch |err| {
            page_ops.freeBlock(graph, block, side);
            return err;
        };
        return block;
    }

    pub fn allocGroup(self: *MutationScratch, graph: *graph_core.GraphCore) !u32 {
        const group = try page_ops.allocGroup(graph);
        self.groups.append(graph.allocator, group) catch |err| {
            page_ops.freeGroup(graph, group);
            return err;
        };
        return group;
    }

    pub fn adoptBlocks(self: *MutationScratch, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide, blocks: []const u32) !void {
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };
        try list.appendSlice(allocator, blocks);
    }

    pub fn disarm(self: *MutationScratch) void {
        self.active = false;
    }

    pub fn cleanup(self: *MutationScratch, graph: *graph_core.GraphCore) void {
        if (!self.active) return;
        for (self.fwd_blocks.items) |b| page_ops.freeBlock(graph, b, .fwd);
        for (self.rev_blocks.items) |b| page_ops.freeBlock(graph, b, .rev);
        for (self.groups.items) |g| page_ops.freeGroup(graph, g);
    }

    pub fn deinit(self: *MutationScratch, allocator: std.mem.Allocator) void {
        self.fwd_blocks.deinit(allocator);
        self.rev_blocks.deinit(allocator);
        self.groups.deinit(allocator);
    }

    pub fn freeGroup(self: *MutationScratch, graph: *graph_core.GraphCore, group: u32) void {
        for (self.groups.items, 0..) |g, i| {
            if (g == group) {
                _ = self.groups.swapRemove(i);
                page_ops.freeGroup(graph, group);
                return;
            }
        }
        page_ops.freeGroup(graph, group);
    }
};
