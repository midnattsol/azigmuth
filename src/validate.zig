//! Structural validation of graph invariants.
//!
//! Two levels of checking are provided:
//!   - `validate`  — fast path: returns `error.CorruptGraph` on the first
//!     violation.  Does not allocate.  Suitable after every mutation.
//!   - `debugValidate` — exhaustive: allocates and returns every violation.
//!     For debugging and tests.

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");

const Side = enum { fwd, rev };

fn readerEnter(graph: *const graph_core.GraphCore) void {
    _ = @constCast(graph).active_readers.fetchAdd(1, .monotonic);
}

fn readerExit(graph: *const graph_core.GraphCore) void {
    _ = @constCast(graph).active_readers.fetchSub(1, .monotonic);
}

fn blockCount(adj: types.NodeAdj, comptime side: Side) u16 {
    return if (side == .fwd) adj.block_count_fwd else adj.block_count_rev;
}

fn groupCount(adj: types.NodeAdj, comptime side: Side) u16 {
    return if (side == .fwd) adj.group_count_fwd else adj.group_count_rev;
}

fn firstBlock(adj: types.NodeAdj, comptime side: Side) u32 {
    return if (side == .fwd) adj.first_block_fwd else adj.first_block_rev;
}

fn firstGroup(adj: types.NodeAdj, comptime side: Side) u32 {
    return if (side == .fwd) adj.first_group_fwd else adj.first_group_rev;
}

fn blockMask(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: Side) u64 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd).mask,
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev).mask,
    };
}

fn blockKey(graph: *const graph_core.GraphCore, block_idx: u32, slot: usize, comptime side: Side) u32 {
    return switch (side) {
        .fwd => page_ops.edgeBlockAtConst(graph, block_idx, .fwd).edges[slot].dest,
        .rev => page_ops.edgeBlockAtConst(graph, block_idx, .rev).sources[slot],
    };
}

fn validateBlockDense(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: Side) !void {
    const mask = blockMask(graph, block_idx, side);
    const live = @popCount(mask);
    if (mask != constants.denseMask(@intCast(live))) return error.CorruptGraph;
}

fn validateDenseInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: Side,
) !void {
    for (start..start + count) |block_idx| {
        try validateBlockDense(graph, @intCast(block_idx), side);
    }
}

fn validateDenseInGroupChain(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    comptime side: Side,
) !void {
    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        try validateDenseInContiguousBlocks(graph, group.start, group.count, side);
        group_idx = group.next;
    }
}

fn validateDenseMasks(graph: *const graph_core.GraphCore, adj: types.NodeAdj, comptime side: Side) !void {
    if (blockCount(adj, side) == 0) return;

    if (groupCount(adj, side) == 0) {
        return validateDenseInContiguousBlocks(graph, firstBlock(adj, side), blockCount(adj, side), side);
    }

    return validateDenseInGroupChain(graph, firstGroup(adj, side), side);
}

fn sumBlockLive(graph: *const graph_core.GraphCore, block_idx: u32, comptime side: Side) u64 {
    return @popCount(blockMask(graph, block_idx, side));
}

fn sumContiguousBlocks(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    comptime side: Side,
) u64 {
    var total: u64 = 0;
    for (start..start + count) |block_idx| {
        total += sumBlockLive(graph, @intCast(block_idx), side);
    }
    return total;
}

fn sumGroupChain(graph: *const graph_core.GraphCore, first_group: u32, comptime side: Side) u64 {
    var total: u64 = 0;
    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        total += sumContiguousBlocks(graph, group.start, group.count, side);
        group_idx = group.next;
    }
    return total;
}

fn sumAdjacency(graph: *const graph_core.GraphCore, adj: types.NodeAdj, comptime side: Side) u64 {
    if (blockCount(adj, side) == 0) return 0;

    if (groupCount(adj, side) == 0) {
        return sumContiguousBlocks(graph, firstBlock(adj, side), blockCount(adj, side), side);
    }

    return sumGroupChain(graph, firstGroup(adj, side), side);
}

fn appendBlockShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    block_idx: u32,
    comptime side: Side,
) !void {
    const mask = blockMask(graph, block_idx, side);
    const live = @popCount(mask);

    if (mask != constants.denseMask(@intCast(live))) {
        try violations.append(allocator, .{ .mask_bit_out_of_range = .{ .node = node_id, .block = block_idx } });
    }

    for (0..live) |slot| {
        const key = blockKey(graph, block_idx, slot, side);
        if (key >= graph.node_count) {
            try violations.append(allocator, .{ .invalid_dst = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot), .dst = key } });
        }
        if (slot > 0 and key <= blockKey(graph, block_idx, slot - 1, side)) {
            try violations.append(allocator, .{ .unsorted_block = .{ .node = node_id, .block = block_idx, .slot = @intCast(slot) } });
        }
    }
}

fn appendContiguousBlockViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    start: u32,
    count: u16,
    comptime side: Side,
) !void {
    for (start..start + count) |block_idx| {
        try appendBlockShapeViolations(graph, allocator, violations, node_id, @intCast(block_idx), side);
    }
}

fn appendGroupChainBlockViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    first_group: u32,
    comptime side: Side,
) !void {
    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        try appendContiguousBlockViolations(graph, allocator, violations, node_id, group.start, group.count, side);
        group_idx = group.next;
    }
}

fn appendAdjacencyShapeViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    node_id: u32,
    adj: types.NodeAdj,
    comptime side: Side,
) !void {
    if (blockCount(adj, side) == 0) return;

    if (groupCount(adj, side) == 0) {
        return appendContiguousBlockViolations(
            graph,
            allocator,
            violations,
            node_id,
            firstBlock(adj, side),
            blockCount(adj, side),
            side,
        );
    }

    return appendGroupChainBlockViolations(graph, allocator, violations, node_id, firstGroup(adj, side), side);
}

fn adjacencyContains(graph: *const graph_core.GraphCore, adj: types.NodeAdj, target: u32, comptime side: Side) bool {
    if (blockCount(adj, side) == 0) return false;

    if (groupCount(adj, side) == 0) {
        return contiguousBlocksContain(graph, firstBlock(adj, side), blockCount(adj, side), target, side);
    }

    return groupChainContains(graph, firstGroup(adj, side), target, side);
}

fn contiguousBlocksContain(
    graph: *const graph_core.GraphCore,
    start: u32,
    count: u16,
    target: u32,
    comptime side: Side,
) bool {
    for (start..start + count) |block_idx| {
        if (blockContains(graph, @intCast(block_idx), target, side)) return true;
    }
    return false;
}

fn groupChainContains(
    graph: *const graph_core.GraphCore,
    first_group: u32,
    target: u32,
    comptime side: Side,
) bool {
    var group_idx = first_group;
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        if (contiguousBlocksContain(graph, group.start, group.count, target, side)) return true;
        group_idx = group.next;
    }
    return false;
}

fn blockContains(graph: *const graph_core.GraphCore, block_idx: u32, target: u32, comptime side: Side) bool {
    const live = @popCount(blockMask(graph, block_idx, side));
    for (0..live) |slot| {
        if (blockKey(graph, block_idx, slot, side) == target) return true;
    }
    return false;
}

fn appendForwardConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    src: u32,
    adj: types.NodeAdj,
) !void {
    if (blockCount(adj, .fwd) == 0) return;

    if (groupCount(adj, .fwd) == 0) {
        return appendForwardConsistencyInContiguousBlocks(graph, allocator, violations, src, firstBlock(adj, .fwd), blockCount(adj, .fwd));
    }

    var group_idx = firstGroup(adj, .fwd);
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        try appendForwardConsistencyInContiguousBlocks(graph, allocator, violations, src, group.start, group.count);
        group_idx = group.next;
    }
}

fn appendForwardConsistencyInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    src: u32,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_idx| {
        try appendForwardConsistencyInBlock(graph, allocator, violations, src, @intCast(block_idx));
    }
}

fn appendForwardConsistencyInBlock(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    src: u32,
    block_idx: u32,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .fwd);
    const live = @popCount(block.mask);

    for (0..live) |slot| {
        const dst = block.edges[slot].dest;
        if (dst >= graph.node_count) continue;

        const dst_adj = page_ops.nodeAtConst(graph, .{ .index = dst }).publishedAdj();
        if (!adjacencyContains(graph, dst_adj, src, .rev)) {
            try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = src, .dst = dst } });
        }
    }
}

fn appendReverseConsistencyViolations(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    dst: u32,
    adj: types.NodeAdj,
) !void {
    if (blockCount(adj, .rev) == 0) return;

    if (groupCount(adj, .rev) == 0) {
        return appendReverseConsistencyInContiguousBlocks(graph, allocator, violations, dst, firstBlock(adj, .rev), blockCount(adj, .rev));
    }

    var group_idx = firstGroup(adj, .rev);
    while (group_idx != constants.END_OF_CHAIN) {
        const group = page_ops.groupAtConst(graph, group_idx);
        try appendReverseConsistencyInContiguousBlocks(graph, allocator, violations, dst, group.start, group.count);
        group_idx = group.next;
    }
}

fn appendReverseConsistencyInContiguousBlocks(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    dst: u32,
    start: u32,
    count: u16,
) !void {
    for (start..start + count) |block_idx| {
        try appendReverseConsistencyInBlock(graph, allocator, violations, dst, @intCast(block_idx));
    }
}

fn appendReverseConsistencyInBlock(
    graph: *const graph_core.GraphCore,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(types.Violation),
    dst: u32,
    block_idx: u32,
) !void {
    const block = page_ops.edgeBlockAtConst(graph, block_idx, .rev);
    const live = @popCount(block.mask);

    for (0..live) |slot| {
        const src = block.sources[slot];
        if (src >= graph.node_count) continue;

        const src_adj = page_ops.nodeAtConst(graph, .{ .index = src }).publishedAdj();
        if (!adjacencyContains(graph, src_adj, dst, .fwd)) {
            try violations.append(allocator, .{ .forward_reverse_mismatch = .{ .node = src, .dst = dst } });
        }
    }
}

/// Fast-path validation. Checks dense masks and global edge-count consistency.
/// Returns `error.CorruptGraph` immediately when the first violation is found.
pub fn validate(graph: *const graph_core.GraphCore) !void {
    readerEnter(graph);
    defer readerExit(graph);

    var total: u64 = 0;

    for (0..graph.node_count) |node_index| {
        const adj = page_ops.nodeAtConst(graph, .{ .index = @intCast(node_index) }).publishedAdj();
        try validateDenseMasks(graph, adj, .fwd);
        try validateDenseMasks(graph, adj, .rev);
        total += sumAdjacency(graph, adj, .fwd);
    }

    if (total != graph.edge_count.load(.acquire)) return error.CorruptGraph;
}

/// Exhaustive validation. Checks block shape, destinations, ordering,
/// forward/reverse consistency, and global edge-count.
pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    readerEnter(graph);
    defer readerExit(graph);

    var violations: std.ArrayList(types.Violation) = .empty;
    var total: u64 = 0;

    for (0..graph.node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adj = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        try appendAdjacencyShapeViolations(graph, allocator, &violations, node_id, adj, .fwd);
        try appendAdjacencyShapeViolations(graph, allocator, &violations, node_id, adj, .rev);
        try appendForwardConsistencyViolations(graph, allocator, &violations, node_id, adj);
        try appendReverseConsistencyViolations(graph, allocator, &violations, node_id, adj);

        total += sumAdjacency(graph, adj, .fwd);
    }

    if (total != graph.edge_count.load(.acquire)) {
        try violations.append(allocator, .{ .edge_count_mismatch = .{ .expected = total, .actual = graph.edge_count.load(.acquire) } });
    }

    return violations.toOwnedSlice(allocator);
}
