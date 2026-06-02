//! Adjacency chain manipulation — groups, block traversal, and edge search.

const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");

pub const AdjSide = enum { fwd, rev };

fn groupCount(node_adj: *const types.NodeAdj, comptime dir: AdjSide) u16 {
    return if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
}

fn firstGroup(node_adj: *const types.NodeAdj, comptime dir: AdjSide) u32 {
    return if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
}

fn setFirstGroup(node_adj: *types.NodeAdj, comptime dir: AdjSide, group_index: u32) void {
    if (dir == .fwd) {
        node_adj.first_group_fwd = group_index;
    } else {
        node_adj.first_group_rev = group_index;
    }
}

/// Copies the published group chain referenced by `node_adj` so subsequent
/// staging mutations can update group metadata without racing lock-free readers
/// that may still be walking the published chain.
pub fn cloneGroupsForStaging(graph: *graph_core.GraphCore, node_adj: *types.NodeAdj, comptime dir: AdjSide) !void {
    const expected_groups = groupCount(node_adj, dir);
    if (expected_groups == 0) return;

    var old_group_index = firstGroup(node_adj, dir);
    var new_first_group: u32 = constants.END_OF_CHAIN;
    var previous_new_group: ?u32 = null;
    var copied_groups: u16 = 0;

    while (copied_groups < expected_groups) : (copied_groups += 1) {
        if (old_group_index == constants.END_OF_CHAIN or old_group_index >= graph.group_count) return error.CorruptGraph;

        const old_group = page_ops.groupAtConst(graph, old_group_index).*;
        const new_group_index = try page_ops.allocGroup(graph);
        page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{
            .start = old_group.start,
            .next = constants.END_OF_CHAIN,
            .count = old_group.count,
        };

        if (previous_new_group) |previous| {
            page_ops.groupAt(graph, previous).next = new_group_index;
        } else {
            new_first_group = new_group_index;
        }
        previous_new_group = new_group_index;
        old_group_index = old_group.next;
    }

    if (old_group_index != constants.END_OF_CHAIN) return error.CorruptGraph;
    setFirstGroup(node_adj, dir, new_first_group);
}

pub fn searchInBlock(comptime BlockType: type, block: *const BlockType, target: u32) ?u7 {
    const live: u7 = @intCast(@popCount(block.mask));
    if (live == 0) return null;

    const first = if (BlockType == types.EdgeBlockFwd) block.edges[0].destination else block.sources[0];
    if (target < first or target > (if (BlockType == types.EdgeBlockFwd) block.edges[live - 1].destination else block.sources[live - 1])) return null;

    var low: u7 = 0;
    var high: u7 = @intCast(live);
    while (low < high) {
        const probe: u7 = low + (high - low) / 2;
        const probe_val = if (BlockType == types.EdgeBlockFwd) block.edges[probe].destination else block.sources[probe];
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

pub fn appendGroupToAdj(graph: *graph_core.GraphCore, node_adj: *types.NodeAdj, new_block: u32, comptime dir: enum { fwd, rev }) !void {
    const group_count = if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;

    if (group_count == 0) {
        const prefix_group_index = try page_ops.allocGroup(graph);
        errdefer page_ops.freeGroup(graph, prefix_group_index);
        const new_group_index = try page_ops.allocGroup(graph);
        page_ops.groupAt(graph, prefix_group_index).* = types.EdgeBlockGroup{
            .start = if (dir == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev,
            .count = if (dir == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev,
            .next = new_group_index,
        };
        page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{ .start = new_block, .count = 1, .next = constants.END_OF_CHAIN };
        if (dir == .fwd) {
            node_adj.first_group_fwd = prefix_group_index;
            node_adj.group_count_fwd = 2;
        } else {
            node_adj.first_group_rev = prefix_group_index;
            node_adj.group_count_rev = 2;
        }
        return;
    }

    const new_group_index = try page_ops.allocGroup(graph);
    errdefer page_ops.freeGroup(graph, new_group_index);
    page_ops.groupAt(graph, new_group_index).* = types.EdgeBlockGroup{ .start = new_block, .count = 1, .next = constants.END_OF_CHAIN };

    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
    var group_index = first_group;
    while (true) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) {
            page_ops.groupAt(graph, group_index).next = new_group_index;
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

pub fn tailBlockIndex(graph: *graph_core.GraphCore, node_adj: *const types.NodeAdj, comptime dir: enum { fwd, rev }) u32 {
    const first = if (dir == .fwd) node_adj.first_block_fwd else node_adj.first_block_rev;
    const total = if (dir == .fwd) node_adj.block_count_fwd else node_adj.block_count_rev;
    const groups = if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev;
    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;

    if (groups == 0) return first + total - 1;

    var group_index = first_group;
    while (true) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) return group.start + group.count - 1;
        group_index = group.next;
    }
}

pub fn extendTailGroup(graph: *graph_core.GraphCore, node_adj: *types.NodeAdj, comptime dir: enum { fwd, rev }) void {
    const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
    var group_index = first_group;
    while (true) {
        const group = page_ops.groupAt(graph, group_index);
        if (group.next == constants.END_OF_CHAIN) {
            group.count += 1;
            break;
        }
        group_index = group.next;
    }
}

pub fn removeTailFromAdj(graph: *graph_core.GraphCore, node_adj: *types.NodeAdj, comptime dir: enum { fwd, rev }) void {
    if ((if (dir == .fwd) node_adj.group_count_fwd else node_adj.group_count_rev) > 0) {
        const first_group = if (dir == .fwd) node_adj.first_group_fwd else node_adj.first_group_rev;
        var group_index = first_group;
        var prev_group: ?u32 = null;
        while (true) {
            const group = page_ops.groupAt(graph, group_index);
            if (group.next == constants.END_OF_CHAIN) {
                page_ops.groupAt(graph, group_index).count -= 1;
                if (page_ops.groupAt(graph, group_index).count == 0) {
                    if (prev_group) |prev| {
                        page_ops.groupAt(graph, prev).next = constants.END_OF_CHAIN;
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
                    page_ops.freeGroup(graph, group_index);
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

pub fn hasEdgeInAdj(graph: *const graph_core.GraphCore, node_adj: types.NodeAdj, target: u32) bool {
    const block_count = node_adj.block_count_fwd;
    if (block_count == 0) return false;

    if (node_adj.group_count_fwd == 0) {
        const first_block = node_adj.first_block_fwd;
        var low: u32 = 0;
        var high: u32 = block_count;
        while (low < high) {
            const mid: u32 = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, first_block + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first_edge = block.edges[0].destination;
            const last_edge = block.edges[live - 1].destination;
            if (target < first_edge) {
                high = mid;
            } else if (target > last_edge) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (first_block..first_block + block_count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        return false;
    }

    var group_index = node_adj.first_group_fwd;
    while (true) {
        const group = page_ops.groupAtConst(graph, group_index);
        var low: u32 = 0;
        var high: u32 = group.count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const block = page_ops.edgeBlockAtConst(graph, group.start + mid, .fwd);
            const live = @popCount(block.mask);
            if (live == 0) break;
            const first = block.edges[0].destination;
            const last = block.edges[live - 1].destination;
            if (target < first) {
                high = mid;
            } else if (target > last) {
                low = mid + 1;
            } else {
                if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
                break;
            }
        }
        for (group.start..group.start + group.count) |block_idx| {
            const block = page_ops.edgeBlockAtConst(graph, @intCast(block_idx), .fwd);
            if (searchInBlock(types.EdgeBlockFwd, block, target) != null) return true;
        }
        if (group.next == constants.END_OF_CHAIN) return false;
        group_index = group.next;
    }
}

pub fn publishedNodeAdj(graph: *const graph_core.GraphCore, node: types.NodeId) !types.NodeAdj {
    if (node.index >= graph.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAtConst(graph, node);
    return node_buffer.publishedAdj();
}

pub fn prepareStagingAdj(graph: *graph_core.GraphCore, node: types.NodeId) !*types.NodeAdj {
    if (node.index >= graph.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAt(graph, node);
    node_buffer.copyPublishedToStaging();
    return node_buffer.stagingAdj();
}

pub fn publishStagingAdj(graph: *graph_core.GraphCore, node: types.NodeId) !void {
    if (node.index >= graph.node_count) return error.InvalidNode;
    const node_buffer = page_ops.nodeAt(graph, node);
    node_buffer.publishStagingAdj();
}
