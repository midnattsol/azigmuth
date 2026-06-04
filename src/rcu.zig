//! RCU-style reader/writer synchronization and block retirement.

const std = @import("std");
const constants = @import("core/constants.zig");
const graph_core = @import("core/graph_core.zig");
const types = @import("core/types.zig");
const page_ops = @import("storage/page_ops.zig");

pub const NO_READER_SLOT: u32 = std.math.maxInt(u32);

pub const ReaderToken = struct {
    slot: u32,
    epoch: u64,
};

pub fn readerEnter(graph: *graph_core.GraphCore) types.GraphError!ReaderToken {
    if (graph.closing.load(.acquire)) return error.GraphBusy;
    while (true) {
        const entry_epoch = graph.epoch.load(.acquire);
        const encoded_epoch = entry_epoch +% 1;

        for (&graph.reader_epochs, 0..) |*slot, slot_index| {
            if (slot.cmpxchgWeak(0, encoded_epoch, .acq_rel, .acquire) == null) {
                if (graph.epoch.load(.acquire) != entry_epoch) {
                    slot.store(0, .release);
                    break;
                }
                // Double-check closing after acquiring the slot.
                if (graph.closing.load(.acquire)) {
                    slot.store(0, .release);
                    return error.GraphBusy;
                }
                _ = graph.active_readers.fetchAdd(1, .monotonic);
                return .{ .slot = @intCast(slot_index), .epoch = entry_epoch };
            }
        } else {
            // Overflow slot — still check closing before committing.
            if (graph.closing.load(.acquire)) return error.GraphBusy;
            _ = graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);
            _ = graph.active_readers.fetchAdd(1, .monotonic);
            return .{ .slot = NO_READER_SLOT, .epoch = entry_epoch };
        }
    }
}

pub fn readerExit(graph: *graph_core.GraphCore, token: ReaderToken) void {
    if (token.slot == NO_READER_SLOT) {
        _ = graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    } else {
        graph.reader_epochs[@intCast(token.slot)].store(0, .release);
    }
    _ = graph.active_readers.fetchSub(1, .monotonic);
}

pub fn retireBlockFwd(graph: *graph_core.GraphCore, block_idx: u32) !void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireBlock(graph, block_idx, current_epoch, .fwd);
}

pub fn retireBlockRev(graph: *graph_core.GraphCore, block_idx: u32) !void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireBlock(graph, block_idx, current_epoch, .rev);
}

pub fn retireGroup(graph: *graph_core.GraphCore, group_idx: u32) void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireGroup(graph, group_idx, current_epoch);
}

pub fn bumpEpoch(graph: *graph_core.GraphCore) void {
    _ = graph.epoch.fetchAdd(1, .release);
}

fn safeReclaimEpoch(graph: *graph_core.GraphCore) ?u64 {
    if (graph.reader_epoch_overflow.load(.acquire) != 0) return null;

    var min_epoch: ?u64 = null;
    for (&graph.reader_epochs) |*slot| {
        const encoded_epoch = slot.load(.acquire);
        if (encoded_epoch == 0) continue;
        const reader_epoch = encoded_epoch - 1;
        min_epoch = if (min_epoch) |current| @min(current, reader_epoch) else reader_epoch;
    }

    return min_epoch orelse graph.epoch.load(.acquire) +% 1;
}

pub fn reclaimRetired(graph: *graph_core.GraphCore) void {
    const safe_epoch = safeReclaimEpoch(graph) orelse return;

    const last_safe_epoch = graph.last_reclaim_epoch.load(.monotonic);
    if (safe_epoch <= last_safe_epoch) return;
    graph.last_reclaim_epoch.store(safe_epoch, .monotonic);

    page_ops.reclaimRetired(graph, safe_epoch, .fwd);
    page_ops.reclaimRetired(graph, safe_epoch, .rev);
    page_ops.reclaimRetiredGroups(graph, safe_epoch);
}
