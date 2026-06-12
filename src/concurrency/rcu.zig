//! RCU-style reader/writer synchronization and block retirement.

const std = @import("std");
const adjacency = @import("../adjacency/mod.zig");
const constants = @import("../core/constants.zig");
const graph_core = @import("../core/graph_core.zig");
const types = @import("../core/types.zig");
const page_ops = @import("../storage/page_ops.zig");

pub const NO_READER_SLOT: u32 = std.math.maxInt(u32);

const builtin = @import("builtin");

const TOKEN_CLOSING_BIT: u32 = 0x8000_0000;
const TOKEN_ACTIVE_MASK: u32 = 0x7FFF_FFFF;

pub const ReaderToken = struct {
    slot: u32,
    liveness_slot: u32,
    epoch: u64,
    id: u64,
};

/// Start slot-scan probes at a per-thread offset so concurrent readers do not
/// all fight over the CAS on the first slots (and their shared cache lines).
fn slotScanOffset(comptime slot_count: usize) usize {
    if (builtin.single_threaded) return 0;
    const thread_id: u64 = @intCast(std.Thread.getCurrentId());
    return @intCast((thread_id *% 0x9E37_79B9_7F4A_7C15) >> 32 & (slot_count - 1));
}

comptime {
    std.debug.assert(std.math.isPowerOfTwo(constants.MAX_READER_SLOTS));
    std.debug.assert(std.math.isPowerOfTwo(graph_core.MAX_TOKEN_LIVENESS_SLOTS));
}

fn nextReaderId(graph: *graph_core.GraphCore) u64 {
    while (true) {
        const reader_id = graph.next_reader_token_id.fetchAdd(1, .acq_rel);
        if (reader_id != 0) return reader_id;
    }
}

fn allocTrackedToken(graph: *graph_core.GraphCore, slot: u32, epoch: u64) !ReaderToken {
    const reader_id = nextReaderId(graph);
    const offset = slotScanOffset(graph_core.MAX_TOKEN_LIVENESS_SLOTS);
    for (0..graph_core.MAX_TOKEN_LIVENESS_SLOTS) |probe| {
        const token_slot_idx = (offset + probe) & (graph_core.MAX_TOKEN_LIVENESS_SLOTS - 1);
        const token_slot = &graph.token_liveness_slots[token_slot_idx];
        if (token_slot.id.cmpxchgWeak(0, reader_id, .acq_rel, .acquire) == null) {
            token_slot.state.store(0, .release);
            return .{ .slot = slot, .liveness_slot = @intCast(token_slot_idx), .epoch = epoch, .id = reader_id };
        }
    }
    return error.GraphBusy;
}

fn releaseTrackedToken(graph: *graph_core.GraphCore, token: ReaderToken) void {
    const token_slot = &graph.token_liveness_slots[@intCast(token.liveness_slot)];
    token_slot.state.store(0, .release);
    token_slot.id.store(0, .release);
}

const CloseTokenResult = enum {
    inactive,
    pending,
    finalize,
};

pub fn beginCloseReaderToken(graph: *const graph_core.GraphCore, token: ReaderToken) CloseTokenResult {
    const token_slot = @constCast(&graph.token_liveness_slots[@intCast(token.liveness_slot)]);
    while (true) {
        if (token_slot.id.load(.acquire) != token.id) return .inactive;
        const state = token_slot.state.load(.acquire);
        if ((state & TOKEN_CLOSING_BIT) != 0) return .pending;
        const desired = state | TOKEN_CLOSING_BIT;
        if (token_slot.state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) {
            return if ((state & TOKEN_ACTIVE_MASK) == 0) .finalize else .pending;
        }
    }
}

pub fn tryRetainReaderToken(graph: *const graph_core.GraphCore, token: ReaderToken) bool {
    const token_slot = @constCast(&graph.token_liveness_slots[@intCast(token.liveness_slot)]);
    while (true) {
        if (token_slot.id.load(.acquire) != token.id) return false;
        const state = token_slot.state.load(.acquire);
        if ((state & TOKEN_CLOSING_BIT) != 0) return false;
        const active = state & TOKEN_ACTIVE_MASK;
        if (active == TOKEN_ACTIVE_MASK) return false;
        if (token_slot.state.cmpxchgWeak(state, state + 1, .acq_rel, .acquire) == null) {
            if (token_slot.id.load(.acquire) == token.id) return true;
            _ = token_slot.state.fetchSub(1, .acq_rel);
            return false;
        }
    }
}

const ReleaseTokenResult = enum {
    alive,
    closed,
    finalize,
};

pub fn releaseRetainedReaderToken(graph: *const graph_core.GraphCore, token: ReaderToken) ReleaseTokenResult {
    const token_slot = @constCast(&graph.token_liveness_slots[@intCast(token.liveness_slot)]);
    while (true) {
        if (token_slot.id.load(.acquire) != token.id) return .closed;
        const state = token_slot.state.load(.acquire);
        const active = state & TOKEN_ACTIVE_MASK;
        std.debug.assert(active != 0);
        const desired = (state & TOKEN_CLOSING_BIT) | (active - 1);
        if (token_slot.state.cmpxchgWeak(state, desired, .acq_rel, .acquire) == null) {
            if ((desired & TOKEN_CLOSING_BIT) == 0) return .alive;
            return if ((desired & TOKEN_ACTIVE_MASK) == 0) .finalize else .closed;
        }
    }
}

pub fn readerEnter(graph: *graph_core.GraphCore) types.GraphError!ReaderToken {
    if (graph.isClosing()) return error.GraphBusy;
    const offset = slotScanOffset(constants.MAX_READER_SLOTS);
    while (true) {
        const entry_epoch = graph.epoch.load(.acquire);
        const encoded_epoch = entry_epoch +% 1;

        for (0..constants.MAX_READER_SLOTS) |probe| {
            const slot_idx = (offset + probe) & (constants.MAX_READER_SLOTS - 1);
            const slot = &graph.reader_epochs[slot_idx];
            if (slot.cmpxchgWeak(0, encoded_epoch, .acq_rel, .acquire) == null) {
                if (graph.epoch.load(.acquire) != entry_epoch) {
                    slot.store(0, .release);
                    break;
                }
                // Double-check closing after acquiring the slot.
                if (graph.isClosing()) {
                    slot.store(0, .release);
                    return error.GraphBusy;
                }
                const token = allocTrackedToken(graph, @intCast(slot_idx), entry_epoch) catch |err| {
                    slot.store(0, .release);
                    return err;
                };
                _ = graph.active_readers.fetchAdd(1, .monotonic);
                return token;
            }
        } else {
            if (graph.isClosing()) return error.GraphBusy;
            const token = try allocTrackedToken(graph, NO_READER_SLOT, entry_epoch);
            _ = graph.reader_epoch_overflow.fetchAdd(1, .acq_rel);
            _ = graph.active_readers.fetchAdd(1, .monotonic);
            return token;
        }
    }
}

pub fn readerExit(graph: *graph_core.GraphCore, token: ReaderToken) void {
    switch (beginCloseReaderToken(graph, token)) {
        .inactive => {},
        .pending => {},
        .finalize => finalizeReaderExit(graph, token),
    }
}

pub fn finalizeReaderExit(graph: *graph_core.GraphCore, token: ReaderToken) void {
    if (token.slot == NO_READER_SLOT) {
        _ = graph.reader_epoch_overflow.fetchSub(1, .acq_rel);
    } else {
        graph.reader_epochs[@intCast(token.slot)].store(0, .release);
    }
    _ = graph.active_readers.fetchSub(1, .monotonic);
    releaseTrackedToken(graph, token);
}

pub fn readerTokenActive(graph: *const graph_core.GraphCore, token: ReaderToken) bool {
    return graph.token_liveness_slots[@intCast(token.liveness_slot)].id.load(.acquire) == token.id;
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

pub fn retireTinySlot(graph: *graph_core.GraphCore, slot_idx: u32, comptime side: adjacency.AdjSide) void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireTinySlot(graph, slot_idx, current_epoch, side);
}

pub fn retireGroupSpan(graph: *graph_core.GraphCore, first_group_idx: u32, group_count: u16) void {
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retireGroupSpan(graph, first_group_idx, group_count, current_epoch);
}

/// Retires one property row (edge_properties mode): the row recycles only
/// after every reader that could observe the dropped edge has exited.
pub fn retirePropRow(graph: *graph_core.GraphCore, row: u32) void {
    if (row == 0) return;
    const current_epoch = graph.epoch.load(.acquire);
    page_ops.retirePropRow(graph, row, current_epoch);
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
    page_ops.reclaimRetiredTinySlots(graph, safe_epoch, .fwd);
    page_ops.reclaimRetiredTinySlots(graph, safe_epoch, .rev);
    page_ops.reclaimRetiredPropRows(graph, safe_epoch);
}
