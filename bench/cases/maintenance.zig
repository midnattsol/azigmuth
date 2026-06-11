const std = @import("std");
const azigmuth = @import("azigmuth");
const harness = @import("../harness.zig");

fn benchRemoveNodeHub(allocator: std.mem.Allocator) !harness.Result {
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    const outgoing: usize = 2048;
    const incoming: usize = 2048;

    for (0..outgoing) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(hub, destination, 0, .{});
    }
    for (0..incoming) |_| {
        const source = try graph.addNode();
        try graph.addEdge(source, hub, 0, .{});
    }

    const start_ns = harness.nowNs();
    const summary = try graph.removeNode(hub);
    const elapsed_ns = harness.nowNs() - start_ns;

    if (summary.removed_visible_edges != outgoing + incoming) return error.CorruptGraph;
    try graph.validate();
    return .{ .ops = outgoing + incoming, .elapsed_ns = elapsed_ns };
}

fn benchRepairBudgetedFlagged(allocator: std.mem.Allocator) !harness.Result {
    var graph = try azigmuth.Graph.init(allocator);
    defer graph.deinit();

    const source_count: usize = 64;
    const fanout: usize = 128;
    const sources = try allocator.alloc(azigmuth.NodeId, source_count);
    defer allocator.free(sources);
    const targets = try allocator.alloc(azigmuth.NodeId, source_count * fanout);
    defer allocator.free(targets);

    for (sources, 0..) |*source, source_idx| {
        source.* = try graph.addNode();
        for (0..fanout) |target_offset| {
            const target_idx = source_idx * fanout + target_offset;
            targets[target_idx] = try graph.addNode();
            try graph.addEdge(source.*, targets[target_idx], 0, .{});
        }
    }

    for (sources, 0..) |_, source_idx| {
        for (0..fanout / 4) |target_offset| {
            const target_idx = source_idx * fanout + target_offset;
            _ = try graph.removeNode(targets[target_idx]);
        }
    }

    var repaired_nodes: usize = 0;
    const start_ns = harness.nowNs();
    while (true) {
        const repaired = try graph.repairBudgeted(1);
        if (repaired == 0) break;
        repaired_nodes += repaired;
    }
    const elapsed_ns = harness.nowNs() - start_ns;

    try graph.validate();
    return .{ .ops = @max(repaired_nodes, 1), .elapsed_ns = elapsed_ns };
}

pub const cases = [_]harness.Case{
    .{ .name = "maintenance.removenode_hub", .run = benchRemoveNodeHub },
    .{ .name = "maintenance.repairbudgeted_flagged", .run = benchRepairBudgetedFlagged },
};
