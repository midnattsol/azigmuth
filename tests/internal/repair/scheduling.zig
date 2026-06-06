//! Repair debt scheduling — verified that needs_repair flags are
//! sufficient for discovery, queues are resilient to stale entries,
//! and repairBudgeted correctly skips removed/ineligible nodes.

const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;

test "repair debt: needs_repair flag alone is sufficient for repairBudgeted discovery" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    for (0..65) |_| {
        const t = try graph.addNode();
        try graph.addEdge(src, t, 0, 0);
    }

    // Remove edges from block 0 to create occupancy debt.
    // Block 0 has 64 entries; remove some to drop below 48.
    for (1..1 + 20) |i| {
        _ = graph.removeEdge(src, .{ .index = @intCast(i) }) catch {};
    }

    // Clear queues so only flag discovery works.
    graph.graph.repair_fwd.clearRetainingCapacity();
    graph.graph.repair_rev.clearRetainingCapacity();

    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired > 0);
    try graph.validate();
}

test "repair debt: stale entries in repair queue do not break repairBudgeted" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    for (0..65) |_| {
        const t = try graph.addNode();
        try graph.addEdge(a, t, 0, 0);
    }
    for (1..1 + 20) |i| {
        _ = graph.removeEdge(a, .{ .index = @intCast(i) }) catch {};
    }

    // Push stale entries — indices beyond node count.
    try graph.graph.repair_fwd.append(graph.graph.allocator, 99999);
    try graph.graph.repair_rev.append(graph.graph.allocator, 99998);

    const repaired = try graph.repairBudgeted(5);
    try testing.expect(repaired > 0);
    try graph.validate();
}

test "repair debt: repairBudgeted ignores removed nodes" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);
    _ = try graph.addNode();

    _ = try graph.removeNode(a);

    // Push the removed node into the repair queue.
    try graph.graph.repair_fwd.append(graph.graph.allocator, a.index);

    const repaired = try graph.repairBudgeted(5);
    // Removed nodes should not consume budget.
    try testing.expectEqual(@as(usize, 0), repaired);

    try graph.validate();
}

test "repair debt: updateRepairDebtSide flags forward tombstones immediately after removeNode" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const src = try graph.addNode();
    const dst = try graph.addNode();
    try graph.addEdge(src, dst, 0, 0);

    _ = try graph.removeNode(dst);

    // src must have needs_repair_fwd set because it still structurally
    // references the removed dst.
    const src_meta = (try graph.nodeAtConst(src)).loadPublishedMeta();
    try testing.expect(src_meta.needs_repair_fwd);

    try graph.validate();
}

test "repair debt: no-op repairBudgeted returns 0 when no debt exists" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    try graph.validate();

    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair debt: repairBudgeted with max_nodes = 0 repairs nothing" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode();
    const b = try graph.addNode();
    try graph.addEdge(a, b, 0, 0);

    try graph.validate();

    const repaired = try graph.repairBudgeted(0);
    try testing.expectEqual(@as(usize, 0), repaired);
}
