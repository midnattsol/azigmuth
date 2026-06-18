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
const index_stack = @import("index_stack.zig");

const EMPTY_INDEX = index_stack.EMPTY_INDEX;
const StackKind = index_stack.StackKind;

fn propRowReclamationAt(graph: *graph_core.GraphCore, row: u32) *types.ReclamationEntry {
    return common.reclamationEntryAt(&graph.prop_row_reclamation_pages, row, constants.PROP_ROWS_PER_PAGE);
}

fn ensurePropRowReclamationPage(graph: *graph_core.GraphCore, page_idx: u32) ![]types.ReclamationEntry {
    return common.ensureReclamationPageSized(graph, &graph.prop_row_reclamation_pages, page_idx, constants.PROP_ROWS_PER_PAGE);
}

fn propRowStackHead(graph: *graph_core.GraphCore, comptime kind: StackKind) *std.atomic.Value(u64) {
    return switch (kind) {
        .free => &graph.free_prop_rows_head,
        .retired => &graph.retired_prop_rows_head,
    };
}

fn propRowStack(graph: *graph_core.GraphCore, comptime kind: StackKind) index_stack.LockFreeIndexStack {
    return index_stack.LockFreeIndexStack.init(propRowStackHead(graph, kind));
}

fn popPropRowStack(graph: *graph_core.GraphCore, comptime kind: StackKind) ?u32 {
    const EntryContext = struct {
        graph: *graph_core.GraphCore,

        pub fn entryAt(self: @This(), row: u32) *types.ReclamationEntry {
            return propRowReclamationAt(self.graph, row);
        }
    };
    return propRowStack(graph, kind).pop(EntryContext{ .graph = graph });
}

/// Returns one property row to the free stack (never-published rows only).
pub fn freePropRow(graph: *graph_core.GraphCore, row: u32) void {
    propRowStack(graph, .free).push(propRowReclamationAt(graph, row), row);
}

/// Moves one property row to the retired stack with its retirement epoch.
pub fn retirePropRow(graph: *graph_core.GraphCore, row: u32, epoch: u64) void {
    const entry = propRowReclamationAt(graph, row);
    entry.retired_epoch.store(epoch, .release);
    propRowStack(graph, .retired).push(entry, row);
}

/// Reclaims retired property rows whose epoch is now safe for reuse.
pub fn reclaimRetiredPropRows(graph: *graph_core.GraphCore, safe_epoch: u64) void {
    var row = propRowStack(graph, .retired).detach();
    while (row != EMPTY_INDEX) {
        const entry = propRowReclamationAt(graph, row);
        const next = entry.next.load(.acquire);
        const retired_epoch = entry.retired_epoch.load(.acquire);
        if (retired_epoch < safe_epoch) {
            freePropRow(graph, row);
        } else {
            propRowStack(graph, .retired).push(entry, row);
        }
        row = next;
    }
}

fn allocFreshPropRow(graph: *graph_core.GraphCore) !u32 {
    while (true) {
        const row = @atomicLoad(u32, &graph.prop_row_count, .acquire);
        if (row == std.math.maxInt(u32)) return error.OutOfMemory;
        const page_idx = common.pageOf(row, constants.PROP_ROWS_PER_PAGE);
        _ = try ensurePropRowReclamationPage(graph, page_idx);
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
        _ = try ensurePropRowReclamationPage(graph, page_idx);
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
