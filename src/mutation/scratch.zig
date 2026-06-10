const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const adjacency = @import("../adjacency/mod.zig");
const page_ops = @import("../storage/page_ops.zig");
const rcu = @import("../concurrency/rcu.zig");

/// Fixed-capacity list that spills to a heap ArrayList only when the inline
/// buffer overflows. Typical mutations track at most a handful of blocks, so
/// the common path never touches the allocator.
fn InlineList(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        const Self = @This();

        inline_items: [inline_capacity]T = undefined,
        inline_len: usize = 0,
        overflow: std.ArrayList(T) = .empty,
        spilled: bool = false,

        pub fn items(self: *const Self) []const T {
            if (self.spilled) return self.overflow.items;
            return self.inline_items[0..self.inline_len];
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            if (!self.spilled) {
                if (self.inline_len < inline_capacity) {
                    self.inline_items[self.inline_len] = item;
                    self.inline_len += 1;
                    return;
                }
                try self.overflow.appendSlice(allocator, self.inline_items[0..self.inline_len]);
                self.spilled = true;
            }
            try self.overflow.append(allocator, item);
        }

        pub fn appendSlice(self: *Self, allocator: std.mem.Allocator, slice: []const T) !void {
            for (slice) |item| try self.append(allocator, item);
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            if (self.spilled) return self.overflow.swapRemove(index);
            const removed = self.inline_items[index];
            self.inline_len -= 1;
            self.inline_items[index] = self.inline_items[self.inline_len];
            return removed;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.overflow.deinit(allocator);
        }
    };
}

pub const MutationScratch = struct {
    const GroupSpan = struct {
        first_group_idx: u32,
        group_count: u16,
    };

    fwd_blocks: InlineList(u32, 8) = .{},
    rev_blocks: InlineList(u32, 8) = .{},
    groups: InlineList(GroupSpan, 4) = .{},
    tiny_fwd_slots: InlineList(u32, 4) = .{},
    tiny_rev_slots: InlineList(u32, 4) = .{},

    /// Published blocks superseded by this mutation. They stay reachable by
    /// readers until publish, so cleanup never touches them; on success the
    /// finalize path retires them via `retireMarked`.
    retire_fwd_blocks: InlineList(u32, 8) = .{},
    retire_rev_blocks: InlineList(u32, 8) = .{},
    active: bool = true,

    /// Marks one currently-published block for retirement after publish.
    pub fn markRetireBlock(self: *MutationScratch, allocator: std.mem.Allocator, comptime side: adjacency.AdjSide, block_idx: u32) !void {
        const list = switch (side) {
            .fwd => &self.retire_fwd_blocks,
            .rev => &self.retire_rev_blocks,
        };
        try list.append(allocator, block_idx);
    }

    /// Retires every block marked via `markRetireBlock`. Call only after the
    /// replacing adjacency has been published.
    pub fn retireMarked(self: *MutationScratch, graph: *graph_core.GraphCore) !void {
        for (self.retire_fwd_blocks.items()) |block_idx| try rcu.retireBlockFwd(graph, block_idx);
        for (self.retire_rev_blocks.items()) |block_idx| try rcu.retireBlockRev(graph, block_idx);
    }

    /// Allocates one tiny slot and tracks it for cleanup if the mutation fails
    /// before publishing. Never-published slots go straight back to the free
    /// stack on cleanup — no epoch wait is needed.
    pub fn allocTinySlot(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !u32 {
        const slot_idx = switch (side) {
            .fwd => try page_ops.allocTinyFwdSlot(graph),
            .rev => try page_ops.allocTinyRevSlot(graph),
        };
        const list = switch (side) {
            .fwd => &self.tiny_fwd_slots,
            .rev => &self.tiny_rev_slots,
        };
        list.append(graph.allocator, slot_idx) catch |err| {
            page_ops.freeTinySlot(graph, slot_idx, side);
            return err;
        };
        return slot_idx;
    }

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
        for (self.fwd_blocks.items()) |b| page_ops.freeBlock(graph, b, .fwd);
        for (self.rev_blocks.items()) |b| page_ops.freeBlock(graph, b, .rev);
        for (self.groups.items()) |group_span| page_ops.freeGroupSpan(graph, group_span.first_group_idx, group_span.group_count);
        for (self.tiny_fwd_slots.items()) |slot_idx| page_ops.freeTinySlot(graph, slot_idx, .fwd);
        for (self.tiny_rev_slots.items()) |slot_idx| page_ops.freeTinySlot(graph, slot_idx, .rev);
    }

    pub fn deinit(self: *MutationScratch, allocator: std.mem.Allocator) void {
        self.fwd_blocks.deinit(allocator);
        self.rev_blocks.deinit(allocator);
        self.groups.deinit(allocator);
        self.tiny_fwd_slots.deinit(allocator);
        self.tiny_rev_slots.deinit(allocator);
        self.retire_fwd_blocks.deinit(allocator);
        self.retire_rev_blocks.deinit(allocator);
    }

    pub fn freeTrackedBlock(self: *MutationScratch, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide, block_idx: u32) void {
        const list = switch (side) {
            .fwd => &self.fwd_blocks,
            .rev => &self.rev_blocks,
        };

        for (list.items(), 0..) |tracked_block_idx, list_idx| {
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
        for (self.groups.items(), 0..) |group_span, i| {
            if (group_span.first_group_idx == first_group_idx and group_span.group_count == group_count) {
                _ = self.groups.swapRemove(i);
                page_ops.freeGroupSpan(graph, first_group_idx, group_count);
                return;
            }
        }
        page_ops.freeGroupSpan(graph, first_group_idx, group_count);
    }
};
