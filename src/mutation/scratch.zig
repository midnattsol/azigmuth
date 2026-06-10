const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const adjacency = @import("../adjacency/mod.zig");
const page_ops = @import("../storage/page_ops.zig");

pub const MutationScratch = struct {
    const GroupSpan = struct {
        first_group_idx: u32,
        group_count: u16,
    };

    fwd_blocks: std.ArrayList(u32) = .empty,
    rev_blocks: std.ArrayList(u32) = .empty,
    groups: std.ArrayList(GroupSpan) = .empty,
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

    pub fn allocFreshBlockSpan(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide, block_count: u32) !u32 {
        const first_block_idx = try page_ops.allocFreshBlockSpan(graph, block_count, side);
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };

        var tracked_blocks: u32 = 0;
        errdefer {
            var block_offset = tracked_blocks;
            while (block_offset > 0) {
                block_offset -= 1;
                page_ops.freeBlock(graph, first_block_idx + block_offset, side);
            }
        }

        while (tracked_blocks < block_count) : (tracked_blocks += 1) {
            try list.append(graph.allocator, first_block_idx + tracked_blocks);
        }
        return first_block_idx;
    }

    pub fn allocGroup(self: *MutationScratch, graph: *graph_core.GraphCore) !u32 {
        return self.allocGroupSpan(graph, 1);
    }

    pub fn allocGroupSpan(self: *MutationScratch, graph: *graph_core.GraphCore, group_count: u16) !u32 {
        const first_group_idx = try page_ops.allocGroupSpan(graph, group_count);
        self.groups.append(graph.allocator, .{ .first_group_idx = first_group_idx, .group_count = group_count }) catch |err| {
            page_ops.freeGroupSpan(graph, first_group_idx, group_count);
            return err;
        };
        return first_group_idx;
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
        for (self.groups.items) |group_span| page_ops.freeGroupSpan(graph, group_span.first_group_idx, group_span.group_count);
    }

    pub fn deinit(self: *MutationScratch, allocator: std.mem.Allocator) void {
        self.fwd_blocks.deinit(allocator);
        self.rev_blocks.deinit(allocator);
        self.groups.deinit(allocator);
    }

    pub fn freeTrackedBlock(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide, block_idx: u32) void {
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };

        for (list.items, 0..) |tracked_block_idx, list_idx| {
            if (tracked_block_idx != block_idx) continue;
            _ = list.swapRemove(list_idx);
            page_ops.freeBlock(graph, block_idx, side);
            return;
        }

        page_ops.freeBlock(graph, block_idx, side);
    }

    pub fn freeGroup(self: *MutationScratch, graph: *graph_core.GraphCore, group: u32) void {
        self.freeGroupSpan(graph, group, 1);
    }

    pub fn freeGroupSpan(self: *MutationScratch, graph: *graph_core.GraphCore, first_group_idx: u32, group_count: u16) void {
        for (self.groups.items, 0..) |group_span, i| {
            if (group_span.first_group_idx == first_group_idx and group_span.group_count == group_count) {
                _ = self.groups.swapRemove(i);
                page_ops.freeGroupSpan(graph, first_group_idx, group_count);
                return;
            }
        }
        page_ops.freeGroupSpan(graph, first_group_idx, group_count);
    }
};
