const std = @import("std");
const internal = @import("../graph.zig");
const public_graph = @import("public_graph.zig");
const cycle_internal = @import("../algorithms/cycle.zig");

pub fn hasCycle(graph: *const public_graph.Graph, allocator: std.mem.Allocator) internal.GraphError!bool {
    const g: *const internal.Graph = @ptrCast(@alignCast(graph));
    return cycle_internal.hasCycle(&g.graph, allocator);
}
