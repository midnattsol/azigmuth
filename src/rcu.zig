//! RCU-style reader/writer synchronization and block retirement.

const std = @import("std");
const constants = @import("constants.zig");
const graph_core = @import("graph_core.zig");
const types = @import("types.zig");
const page_ops = @import("page_ops.zig");

pub const NO_READER_SLOT: u32 = std.math.maxInt(u32);

pub const ReaderToken = struct {
    slot: u32,
    epoch: u64,
};

pub fn readerEnter(graph: *graph_core.GraphCore) ReaderToken {
    const entry_epoch = graph.epoch.load(.acquire);
    const encoded_epoch = entry_epoch +% 1;

    for (&graph.reader_epochs, 0..) |*slot, slot_index| {
        if (slot.cmpxchgWeak(0, encoded_epoch, .acq_rel, .acquire) == null) {
            _ = graph.active_readers.fetchAdd(1, .monotonic);
            return .{ .slot = @intCast(slot_index), .epoch = entry_epoch };
        }
    }

    _ = graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);
    _ = graph.active_readers.fetchAdd(1, .monotonic);
    return .{ .slot = NO_READER_SLOT, .epoch = entry_epoch };
}

pub fn readerExit(graph: *graph_core.GraphCore, token: ReaderToken) void {
    if (token.slot == NO_READER_SLOT) {
        _ = graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    } else {
        graph.reader_epochs[@intCast(token.slot)].store(0, .release);
    }
    _ = graph.active_readers.fetchSub(1, .monotonic);
}

pub fn ensureRetireCapacity(graph: *graph_core.GraphCore, fwd_count: usize, rev_count: usize) !void {
    _ = graph;
    _ = fwd_count;
    _ = rev_count;
}

fn appendDebugRetired(graph: *graph_core.GraphCore, list: *std.ArrayList(types.RetiredBlock), item: types.RetiredBlock) void {
    if (!graph.debug_retired_enabled.load(.monotonic)) return;
    while (true) {
        const len = @atomicLoad(usize, &list.items.len, .acquire);
        if (len >= list.capacity) return;
        if (@cmpxchgWeak(usize, &list.items.len, len, len + 1, .acq_rel, .acquire) == null) {
            list.items.ptr[len] = item;
            return;
        }
    }
}

pub fn retireBlockFwd(graph: *graph_core.GraphCore, block_idx: u32) !void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireBlock(graph, block_idx, current_epoch, .fwd);
    appendDebugRetired(graph, &graph.retired_blocks_fwd, .{ .block = block_idx, .epoch = current_epoch });
}

pub fn retireBlockRev(graph: *graph_core.GraphCore, block_idx: u32) !void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireBlock(graph, block_idx, current_epoch, .rev);
    appendDebugRetired(graph, &graph.retired_blocks_rev, .{ .block = block_idx, .epoch = current_epoch });
}

pub fn retireGroup(graph: *graph_core.GraphCore, group_idx: u32) void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireGroup(graph, group_idx, current_epoch);
}

pub fn bumpEpoch(graph: *graph_core.GraphCore) void {
    _ = graph.epoch.fetchAdd(1, .monotonic);
}

fn safeReclaimEpoch(graph: *graph_core.GraphCore) ?u64 {
    if (graph.reader_epoch_overflow.load(.acquire) != 0) return null;

    // Fast path: no readers active, no need to scan slots.
    if (graph.active_readers.load(.acquire) == 0) return graph.epoch.load(.acquire) +% 1;

    var min_epoch: ?u64 = null;
    for (&graph.reader_epochs) |*slot| {
        const encoded_epoch = slot.load(.acquire);
        if (encoded_epoch == 0) continue;
        const reader_epoch = encoded_epoch - 1;
        min_epoch = if (min_epoch) |current| @min(current, reader_epoch) else reader_epoch;
    }

    return min_epoch orelse graph.epoch.load(.acquire) +% 1;
}

fn pruneDebugRetired(graph: *graph_core.GraphCore, safe_epoch: u64, comptime side: enum { fwd, rev }) void {
    const list = if (side == .fwd) &graph.retired_blocks_fwd else &graph.retired_blocks_rev;
    while (list.items.len > 0) {
        if (list.items[0].epoch >= safe_epoch) break;
        _ = list.orderedRemove(0);
    }
}

pub fn reclaimRetired(graph: *graph_core.GraphCore) void {
    const safe_epoch = safeReclaimEpoch(graph) orelse return;

    // Skip reclaim if safe_epoch has not advanced since the last pass.
    // Without this, every mutation under a long reader would detach and
    // re-push the entire retired stack — O(M²) accumulated cost.
    const last_safe_epoch = graph.last_reclaim_epoch.load(.monotonic);
    if (safe_epoch <= last_safe_epoch) return;
    graph.last_reclaim_epoch.store(safe_epoch, .monotonic);

    page_ops.reclaimRetired(graph, safe_epoch, .fwd);
    page_ops.reclaimRetired(graph, safe_epoch, .rev);
    page_ops.reclaimRetiredGroups(graph, safe_epoch);

    if (graph.active_writers.load(.monotonic) == 0) {
        if (graph.debug_retired_enabled.load(.monotonic)) {
            pruneDebugRetired(graph, safe_epoch, .fwd);
            pruneDebugRetired(graph, safe_epoch, .rev);
        } else {
            @atomicStore(usize, &graph.retired_blocks_fwd.items.len, 0, .release);
            @atomicStore(usize, &graph.retired_blocks_rev.items.len, 0, .release);
            graph.free_blocks_fwd.clearRetainingCapacity();
            graph.free_blocks_rev.clearRetainingCapacity();
            graph.free_groups.clearRetainingCapacity();
        }
    }
}
