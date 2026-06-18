const std = @import("std");
const graph_core = @import("../../../core/graph_core.zig");
const node_bitmap = @import("../../../core/node_bitmap.zig");
const node_access = @import("../../../core/node_access.zig");
const node_publication_mod = @import("../../../storage/node/publication.zig");
const page_ops = @import("../../../storage/page_ops.zig");
const types = @import("../../../core/types.zig");
const adjacency = @import("../../../adjacency/mod.zig");

fn repairCursor(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *u32 {
    return switch (side) {
        .fwd => &graph.repair_scan_cursor_fwd,
        .rev => &graph.repair_scan_cursor_rev,
    };
}

pub fn getRepairFlag(adj: *const types.NodeAdj, comptime side: adjacency.AdjSide) bool {
    return switch (side) {
        .fwd => adj.flags.needs_repair_fwd,
        .rev => adj.flags.needs_repair_rev,
    };
}

pub fn setRepairFlag(adj: *types.NodeAdj, comptime side: adjacency.AdjSide, value: bool) void {
    switch (side) {
        .fwd => adj.flags.needs_repair_fwd = value,
        .rev => adj.flags.needs_repair_rev = value,
    }
}

pub fn writePublishedRepairFlag(
    node_publication: *node_publication_mod.NodePublicationCell,
    comptime side: adjacency.AdjSide,
    value: bool,
) void {
    var expected = node_publication.loadPublicationState();
    while (true) {
        var desired = expected;
        switch (side) {
            .fwd => desired.needs_repair_fwd = value,
            .rev => desired.needs_repair_rev = value,
        }
        const actual = node_publication.cmpxchgPublicationState(expected, desired) orelse break;
        expected = actual;
    }
}

fn repairQueue(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *std.ArrayList(u32) {
    return switch (side) {
        .fwd => &graph.repair_fwd,
        .rev => &graph.repair_rev,
    };
}

fn lockRepairQueue(graph: *graph_core.GraphCore) void {
    while (graph.repair_queue_lock.cmpxchgWeak(0, 1, .acq_rel, .acquire) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockRepairQueue(graph: *graph_core.GraphCore) void {
    graph.repair_queue_lock.store(0, .release);
}

fn repairQueuePages(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) *graph_core.GraphCore.NodePageDirectory {
    return switch (side) {
        .fwd => &graph.repair_queued_fwd_pages,
        .rev => &graph.repair_queued_rev_pages,
    };
}

pub fn enqueueRepairDebtBestEffort(graph: *graph_core.GraphCore, node_idx: u32, comptime side: adjacency.AdjSide) void {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);

    if (node_bitmap.testAndSetBit(graph, repairQueuePages(graph, side), node_idx) catch true) return;
    repairQueue(graph, side).append(graph.allocator, node_idx) catch {
        _ = node_bitmap.testAndClearBit(repairQueuePages(graph, side), node_idx);
    };
}

pub fn popRepairDebtBestEffort(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);

    const queue = repairQueue(graph, side);
    while (queue.pop()) |node_idx| {
        _ = node_bitmap.testAndClearBit(repairQueuePages(graph, side), node_idx);
        return node_idx;
    }
    return null;
}

fn nodeNeedsRepair(graph: *const graph_core.GraphCore, node_idx: u32, comptime side: adjacency.AdjSide) bool {
    const adj = node_access.publishedAdjAtConst(graph, .{ .index = node_idx });
    if (adj.flags.removed) return false;
    return switch (side) {
        .fwd => adj.flags.needs_repair_fwd,
        .rev => adj.flags.needs_repair_rev,
    };
}

pub fn queuedRepairCount(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) usize {
    lockRepairQueue(graph);
    defer unlockRepairQueue(graph);
    return repairQueue(graph, side).items.len;
}

pub fn countNodesWithRepairFlag(graph: *const graph_core.GraphCore, comptime side: adjacency.AdjSide) usize {
    const node_count = graph.publishedNodeCount();
    var total: usize = 0;
    for (0..node_count) |node_idx_usize| {
        const node_idx: u32 = @intCast(node_idx_usize);
        if (nodeNeedsRepair(graph, node_idx, side)) total += 1;
    }
    return total;
}

pub fn findRepairDebtByFlag(graph: *graph_core.GraphCore, comptime side: adjacency.AdjSide) ?u32 {
    const cursor = repairCursor(graph, side);
    const node_count = graph.publishedNodeCount();
    if (node_count == 0) return null;
    if (cursor.* >= node_count) cursor.* = 0;

    var node_idx = cursor.*;
    while (node_idx < node_count) : (node_idx += 1) {
        if (nodeNeedsRepair(graph, node_idx, side)) {
            cursor.* = node_idx + 1;
            return node_idx;
        }
    }

    node_idx = 0;
    while (node_idx < cursor.*) : (node_idx += 1) {
        if (nodeNeedsRepair(graph, node_idx, side)) {
            cursor.* = node_idx + 1;
            return node_idx;
        }
    }
    return null;
}
