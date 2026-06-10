const std = @import("std");
const constants = @import("../../../core/constants.zig");
const graph_core = @import("../../../core/graph_core.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const adjacency = @import("../../../adjacency/mod.zig");
const side_ops = @import("../../../adjacency/side_ops.zig");
const rebuild_filter = @import("filter.zig");
const rebuild_heap = @import("heap.zig");

const OutputState = struct {
    new_blocks: std.ArrayList(u32),
    out_block_idx: ?u32 = null,
    out_slot: u7 = 0,

    fn init(
        graph: *graph_core.GraphCore,
        allocator: std.mem.Allocator,
        comptime side: adjacency.AdjSide,
        live_after: usize,
    ) !OutputState {
        const out_block_count = (live_after + 63) / 64;
        var new_blocks = try std.ArrayList(u32).initCapacity(allocator, out_block_count);
        errdefer {
            for (new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, side);
            new_blocks.deinit(allocator);
        }
        return .{ .new_blocks = new_blocks };
    }

    fn ensureBlock(self: *OutputState, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) !void {
        if (self.out_block_idx != null and self.out_slot < 64) return;
        self.out_block_idx = try page_ops.allocBlock(graph, side);
        self.new_blocks.appendAssumeCapacity(self.out_block_idx.?);
        self.out_slot = 0;
    }

    fn appendIter(self: *OutputState, graph: *graph_core.GraphCore, iter: rebuild_heap.BlockIter, comptime side: adjacency.AdjSide) !void {
        try self.ensureBlock(graph, side);
        writeItem(graph, self.out_block_idx.?, self.out_slot, iter, side);
        self.out_slot += 1;
        if (self.out_slot == 64) {
            page_ops.edgeBlockAt(graph, self.out_block_idx.?, side).mask = constants.FULL_BLOCK_MASK;
        }
    }

    fn finish(self: *OutputState, graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) void {
        if (self.out_block_idx) |block_idx| {
            page_ops.edgeBlockAt(graph, block_idx, side).mask = constants.denseMask(self.out_slot);
        }
    }
};

fn writeItem(
    graph: *graph_core.GraphCore,
    out_block_idx: u32,
    out_slot: u7,
    iter: rebuild_heap.BlockIter,
    comptime side: adjacency.AdjSide,
) void {
    switch (side) {
        .fwd => {
            const entry = side_ops.readForwardEntryAtSlot(graph, iter.block_idx, iter.pos);
            const out_block = page_ops.edgeBlockAt(graph, out_block_idx, .fwd);
            out_block.destinations[out_slot] = entry.destination;
            out_block.relations[out_slot] = entry.relation;
            out_block.flags[out_slot] = @bitCast(entry.flags);
            if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, out_block_idx).ids[out_slot] = entry.edge_id;
        },
        .rev => {
            page_ops.edgeBlockAt(graph, out_block_idx, .rev).sources[out_slot] = side_ops.readNodeIdAtSlot(graph, iter.block_idx, iter.pos, .rev);
        },
    }
}

pub fn emitMergedBlocks(
    graph: *graph_core.GraphCore,
    heap: *std.ArrayList(rebuild_heap.BlockIter),
    comptime side: adjacency.AdjSide,
    live_after: usize,
    allocator: std.mem.Allocator,
    skip_source: ?u32,
) !std.ArrayList(u32) {
    var output_state = try OutputState.init(graph, allocator, side, live_after);
    errdefer {
        for (output_state.new_blocks.items) |block_idx| page_ops.freeBlock(graph, block_idx, side);
        output_state.new_blocks.deinit(allocator);
    }

    while (heap.items.len > 0) {
        const current_iter = heap.items[0];
        try output_state.appendIter(graph, current_iter, side);

        var next_iter = current_iter;
        if (!rebuild_filter.advanceIter(graph, &next_iter, side, skip_source)) {
            rebuild_heap.heapRemoveTop(heap);
        } else {
            rebuild_heap.heapUpdateTop(heap, next_iter);
        }
    }

    output_state.finish(graph, side);
    return output_state.new_blocks;
}
