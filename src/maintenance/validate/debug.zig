//! Debug validation — exhaustive allocating checks.
//! Live debug validation audits the mutable engine state; snapshot debug
//! validation audits only the captured view plus the referenced adjacency data.

const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const snapshot_view = @import("../../query/snapshot/view.zig");
const std = @import("std");
const common = @import("common.zig");
const driver = @import("debug/driver.zig");

pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    const reader_token = try common.readerEnter(graph);
    defer common.readerExit(graph, reader_token);
    return driver.debugValidateLive(graph, allocator);
}

pub fn debugValidateSnapshot(
    graph: *const graph_core.GraphCore,
    view: *const snapshot_view.CapturedGraphView,
    allocator: std.mem.Allocator,
) ![]types.Violation {
    return driver.debugValidateSnapshot(graph, view, allocator);
}
