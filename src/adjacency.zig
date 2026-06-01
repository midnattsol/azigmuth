//! Adjacency chain manipulation — groups, block traversal, and edge search.

const constants = @import("constants.zig");
const graph = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");

pub const AdjSide = enum { fwd, rev };

pub fn searchInBlock(comptime BlockType: type, block: *const BlockType, target: u32) ?u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    if (live == 0) return null;

    const first = if (BlockType == types.EdgeBlockFwd) block.edges[0].dest else block.sources[0];
    if (target < first or target > (if (BlockType == types.EdgeBlockFwd) block.edges[live - 1].dest else block.sources[live - 1])) return null;

    var low: u7 = 0;
    var high: u7 = @intCast(live);
    while (low < high) {
        const probe: u7 = low + (high - low) / 2;
        const probe_val = if (BlockType == types.EdgeBlockFwd) block.edges[probe].dest else block.sources[probe];
        if (probe_val < target) {
            low = probe + 1;
        } else if (probe_val == target) {
            return probe;
        } else {
            high = probe;
        }
    }
    return null;
}

pub fn appendGroupToAdj(core: *graph.GraphCore, node_adj: *types.NodeAdj, new_block: u32, comptime dir: enum { fwd, rev }) !void {
    const new_group_index = try page_ops.allocGroup(core);
    page_ops.groupAt(core, new_group_index).* = types.EdgeBlockGroup{ .start = new_block, .count = 1, .next = constants.END_OF_CHAIN };

    const group_count = if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
    const first_block = if (dir == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    const block_count = if (dir == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;

    if (group_count == 0) {
        const prefix_group_index = try page_ops.allocGroup(core);
        page_ops.groupAt(core, prefix_group_index).* = types.EdgeBlockGroup{ .start = first_block, .count = block_count, .next = new_group_index };
        if (dir == .fwd) {
            node_adj.first_group_fwd = prefix_group_index;
            node_adj.group_count_fwd = 2;
        } else {
            node_adj.first_group_rev = prefix_group_index;
            node_adj.group_count_rev = 2;
        }
    } else {
        var group_index = first_group;
        while (true) {
            const group = page_ops.groupAt(core, group_index);
            if (group.next == constants.END_OF_CHAIN) {
                page_ops.groupAt(core, group_index).next = new_group_index;
                break;
            }
            group_index = group.next;
        }
        if (dir == .fwd) {
            node_adj.group_count_fwd += 1;
        } else {
            node_adj.group_count_rev += 1;
        }
    }
}

pub fn tailBlockIndex(core: *graph.GraphCore, node_adj: *const types.NodeAdj, comptime dir: enum { fwd, rev }) u32 {
    const first = if (dir == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    const total = if (dir == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    const groups = if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;

    if (groups == 0) return first + total - 1;

    var group_index = first_group;
    while (true) {
        const group = page_ops.groupAt(core, group_index);
        if (group.next == constants.END_OF_CHAIN) return group.start + group.count - 1;
        group_index = group.next;
    }
}

pub fn extendTailGroup(core: *graph.GraphCore, node_adj: *types.NodeAdj, comptime dir: enum { fwd, rev }) void {
    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
    var group_index = first_group;
    while (true) {
        const group = page_ops.groupAt(core, group_index);
        if (group.next == constants.END_OF_CHAIN) {
            group.count += 1;
            break;
        }
        group_index = group.next;
    }
}

pub fn removeTailFromAdj(core: *graph.GraphCore, node_adj: *types.NodeAdj, comptime dir: enum { fwd, rev }) void {
    if ((if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev) > 0) {
        const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
        var group_index = first_group;
        var prev_group: ?u32 = null;
        while (true) {
            const group = page_ops.groupAt(core, group_index);
            if (group.next == constants.END_OF_CHAIN) {
                page_ops.groupAt(core, group_index).count -= 1;
                if (page_ops.groupAt(core, group_index).count == 0) {
                    if (prev_group) |prev| {
                        page_ops.groupAt(core, prev).next = constants.END_OF_CHAIN;
                    } else {
                        if (dir == .fwd) {
                            node_adj.group_count_fwd = 0;
                            node_adj.first_group_fwd = 0;
                        } else {
                            node_adj.group_count_rev = 0;
                            node_adj.first_group_rev = 0;
                        }
                    }
                    if (dir == .fwd) {
                        node_adj.group_count_fwd -= 1;
                    } else {
                        node_adj.group_count_rev -= 1;
                    }
                    page_ops.freeGroup(core, group_index);
                }
                break;
            }
            prev_group = group_index;
            group_index = group.next;
        }
    } else {
        if (dir == .fwd) {
            node_adj.block_count_fwd -= 1;
        } else {
            node_adj.block_count_rev -= 1;
        }
    }
}

pub fn hasEdgeInAdj(core: *const graph.GraphCore, node_adj: types.NodeAdj, target: u32) bool {
    if (node_adj.block_count_fwd == 0) return false;

    if (node_adj.group_count_fwd == 0) {
        const first_block = node_adj.first_block_fwd;
        var block_offset: u32 = 0;
        while (block_offset < node_adj.block_count_fwd) : (block_offset += 1) {
            if (searchInBlock(types.EdgeBlockFwd, page_ops.edgeBlockAtConst(core, first_block + block_offset, .fwd), target) != null) return true;
        }
        return false;
    }

    var group_index = node_adj.first_group_fwd;
    while (true) {
        const group = page_ops.groupAtConst(core, group_index);
        var block_offset: u32 = 0;
        while (block_offset < group.count) : (block_offset += 1) {
            if (searchInBlock(types.EdgeBlockFwd, page_ops.edgeBlockAtConst(core, group.start + block_offset, .fwd), target) != null) return true;
        }
        if (group.next == constants.END_OF_CHAIN) return false;
        group_index = group.next;
    }
}

pub fn publishedNodeAdj(core: *const graph.GraphCore, node: types.NodeId) !types.NodeAdj {
    if (node.index >= core.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAtConst(core, node);
    return node_buffer.publishedAdj();
}

pub fn prepareStagingAdj(core: *graph.GraphCore, node: types.NodeId) !*types.NodeAdj {
    if (node.index >= core.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAt(core, node);
    node_buffer.copyPublishedToStaging();
    return node_buffer.stagingAdj();
}

pub fn publishStagingAdj(core: *graph.GraphCore, node: types.NodeId) !void {
    if (node.index >= core.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAt(core, node);
    node_buffer.publishStagingAdj();
}
