//! Page-based indexed access and allocation for graph storage.

const std = @import("std");
const constants = @import("constants.zig");
const graph = @import("graph_core.zig");
const types = @import("types.zig");
const adjacency = @import("adjacency.zig");

pub inline fn pageOf(index: u32, comptime entries_per_page: u32) u32 {
    return index / entries_per_page;
}

pub inline fn slotOf(index: u32, comptime entries_per_page: u32) u32 {
    return index % entries_per_page;
}

pub inline fn makeIndex(page_index: u32, slot_index: u32, comptime entries_per_page: u32) u32 {
    return page_index * entries_per_page + slot_index;
}

pub fn nodeAt(core: *graph.GraphCore, id: types.NodeId) *types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    return &core.node_pages.items[page_index][slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeAtConst(core: *const graph.GraphCore, id: types.NodeId) *const types.NodeBuffer {
    const page_index = pageOf(id.index, constants.NODES_PER_PAGE);
    return &core.node_pages.items[page_index][slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn edgeBlockFwdAt(core: *graph.GraphCore, block_index: u32) *types.EdgeBlockFwd {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &core.edge_blocks_fwd.items[page_index][slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockFwdAtConst(core: *const graph.GraphCore, block_index: u32) *const types.EdgeBlockFwd {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &core.edge_blocks_fwd.items[page_index][slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockRevAt(core: *graph.GraphCore, block_index: u32) *types.EdgeBlockRev {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &core.edge_blocks_rev.items[page_index][slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockRevAtConst(core: *const graph.GraphCore, block_index: u32) *const types.EdgeBlockRev {
    const page_index = pageOf(block_index, constants.EDGE_BLOCKS_PER_PAGE);
    return &core.edge_blocks_rev.items[page_index][slotOf(block_index, constants.EDGE_BLOCKS_PER_PAGE)];
}

pub fn edgeBlockAt(core: *graph.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *types.EdgeBlockFwd,
    .rev => *types.EdgeBlockRev,
} {
    if (side == .fwd) return edgeBlockFwdAt(core, block_index);
    if (side == .rev) return edgeBlockRevAt(core, block_index);
}

pub fn edgeBlockAtConst(core: *const graph.GraphCore, block_index: u32, comptime side: adjacency.AdjSide) switch (side) {
    .fwd => *const types.EdgeBlockFwd,
    .rev => *const types.EdgeBlockRev,
} {
    if (side == .fwd) return edgeBlockFwdAtConst(core, block_index);
    if (side == .rev) return edgeBlockRevAtConst(core, block_index);
}

pub fn groupAt(core: *graph.GraphCore, group_index: u32) *types.EdgeBlockGroup {
    const page_index = pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    return &core.edge_block_groups.items[page_index][slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)];
}

pub fn groupAtConst(core: *const graph.GraphCore, group_index: u32) *const types.EdgeBlockGroup {
    const page_index = pageOf(group_index, constants.EDGE_GROUPS_PER_PAGE);
    return &core.edge_block_groups.items[page_index][slotOf(group_index, constants.EDGE_GROUPS_PER_PAGE)];
}

pub fn allocBlock(core: *graph.GraphCore, comptime side: adjacency.AdjSide) !u32 {
    return switch (side) {
        .fwd => blk: {
            if (core.free_blocks_fwd.items.len > 0) {
                if (core.free_blocks_fwd.pop()) |idx| {
                    edgeBlockFwdAt(core, idx).* = std.mem.zeroes(types.EdgeBlockFwd);
                    break :blk idx;
                }
            }
            const block_index = core.block_fwd_count;
            core.block_fwd_count += 1;
            if (block_index % constants.EDGE_BLOCKS_PER_PAGE == 0) {
                const new_page = try core.allocator.alloc(types.EdgeBlockFwd, constants.EDGE_BLOCKS_PER_PAGE);
                @memset(new_page, std.mem.zeroes(types.EdgeBlockFwd));
                try core.edge_blocks_fwd.append(core.allocator, new_page);
            }
            break :blk block_index;
        },
        .rev => blk: {
            if (core.free_blocks_rev.items.len > 0) {
                if (core.free_blocks_rev.pop()) |idx| {
                    edgeBlockRevAt(core, idx).* = std.mem.zeroes(types.EdgeBlockRev);
                    break :blk idx;
                }
            }
            const block_index = core.block_rev_count;
            core.block_rev_count += 1;
            if (block_index % constants.EDGE_BLOCKS_PER_PAGE == 0) {
                const new_page = try core.allocator.alloc(types.EdgeBlockRev, constants.EDGE_BLOCKS_PER_PAGE);
                @memset(new_page, std.mem.zeroes(types.EdgeBlockRev));
                try core.edge_blocks_rev.append(core.allocator, new_page);
            }
            break :blk block_index;
        },
    };
}

pub fn allocGroup(core: *graph.GraphCore) !u32 {
    if (core.free_groups.items.len > 0) {
        if (core.free_groups.pop()) |idx| return idx;
    }

    const group_index = core.group_count;
    core.group_count += 1;

    if (group_index % constants.EDGE_GROUPS_PER_PAGE == 0) {
        const new_page = try core.allocator.alloc(types.EdgeBlockGroup, constants.EDGE_GROUPS_PER_PAGE);
        @memset(new_page, std.mem.zeroes(types.EdgeBlockGroup));
        try core.edge_block_groups.append(core.allocator, new_page);
    }
    return group_index;
}

pub fn freeGroup(core: *graph.GraphCore, group_index: u32) void {
    core.free_groups.append(core.allocator, group_index) catch {};
}
