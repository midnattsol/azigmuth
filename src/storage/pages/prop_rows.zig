//! Property-row lifecycle (edge_properties mode). Rows follow the same
//! retire/reclaim discipline as edge blocks and tiny slots: removal retires
//! the row with the current epoch; reclaim moves epoch-safe rows back to
//! the free stack for reuse.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("common.zig");

const EMPTY_INDEX = common.EMPTY_INDEX;
const StackKind = common.StackKind;

fn propRowMetaAt(graph: *graph_core.GraphCore, row: u32) *types.BlockMeta {
    return common.metaEntryAt(&graph.prop_row_meta_pages, row, constants.PROP_ROWS_PER_PAGE);
}

fn ensurePropRowMetaPage(graph: *graph_core.GraphCore, page_idx: u32) ![]types.BlockMeta {
    return common.ensureMetaPageSized(graph, &graph.prop_row_meta_pages, page_idx, constants.PROP_ROWS_PER_PAGE);
}

fn propRowStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => &graph.free_prop_rows_head,
        .retired => &graph.retired_prop_rows_head,
    };
}

fn popPropRowStack(graph: *graph_core.GraphCore, comptime kind: StackKind) ?u32 {
    const head = propRowStackHead(graph, kind);
    while (true) {
        const old_head = head.load(.acquire);
        const row = common.headIndex(old_head);
        if (row == EMPTY_INDEX) return null;
        const meta = propRowMetaAt(graph, row);
        const next = meta.next.load(.acquire);
        const new_head = common.packHead(next, common.headTag(old_head) +% 1);
        if (head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return row;
    }
}

/// Returns one property row to the free stack (never-published rows only).
pub fn freePropRow(graph: *graph_core.GraphCore, row: u32) void {
    common.pushHeadIndex(propRowStackHead(graph, .free), propRowMetaAt(graph, row), row);
}

/// Moves one property row to the retired stack with its retirement epoch.
pub fn retirePropRow(graph: *graph_core.GraphCore, row: u32, epoch: u64) void {
    const meta = propRowMetaAt(graph, row);
    meta.epoch.store(epoch, .release);
    common.pushHeadIndex(propRowStackHead(graph, .retired), meta, row);
}

/// Reclaims retired property rows whose epoch is now safe for reuse.
pub fn reclaimRetiredPropRows(graph: *graph_core.GraphCore, safe_epoch: u64) void {
    var row = common.detachHeadIndex(propRowStackHead(graph, .retired));
    while (row != EMPTY_INDEX) {
        const meta = propRowMetaAt(graph, row);
        const next = meta.next.load(.acquire);
        const retired_epoch = meta.epoch.load(.acquire);
        if (retired_epoch < safe_epoch) {
            freePropRow(graph, row);
        } else {
            common.pushHeadIndex(propRowStackHead(graph, .retired), meta, row);
        }
        row = next;
    }
}

fn allocFreshPropRow(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const row = @atomicLoad(u32, &graph.prop_row_count, .acquire);
        if (row == std.math.maxInt(u32)) return error.OutOfMemory;
        const page_idx = common.pageOf(row, constants.PROP_ROWS_PER_PAGE);
        _ = try ensurePropRowMetaPage(graph, page_idx);
        if (@cmpxchgWeak(u32, &graph.prop_row_count, row, row + 1, .acq_rel, .acquire) == null) {
            return row;
        }
    }
}

/// Ensures lifecycle metadata pages exist for rows below `required_row_count`
/// (builder bulk assignment bypasses allocPropRow's lazy page growth).
pub fn ensurePropRowCapacity(graph: *graph_core.GraphCore, required_row_count: u32) !void {
    if (required_row_count == 0) return;
    const last_page_idx = common.pageOf(required_row_count - 1, constants.PROP_ROWS_PER_PAGE);
    var page_idx: u32 = common.pageOf(graph.loadPropRowCount(), constants.PROP_ROWS_PER_PAGE);
    while (page_idx <= last_page_idx) : (page_idx += 1) {
        _ = try ensurePropRowMetaPage(graph, page_idx);
    }
}

/// Allocates one property row, reusing the free stack when available.
/// Falls back to a last-resort reclaim pass before failing (see allocBlock).
pub fn allocPropRow(graph: *graph_core.GraphCore) !u32 {
    if (popPropRowStack(graph, .free)) |row| return row;
    return allocFreshPropRow(graph) catch |err| switch (err) {
        error.OutOfMemory => {
            rcu.reclaimRetired(graph);
            return popPropRowStack(graph, .free) orelse err;
        },
    };
}
