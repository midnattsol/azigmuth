//! Edge-property rows: stable ids per edge, lifecycle through
//! COW/repair/removal, caller-owned columns, and CSR export alignment.

const std = @import("std");
const graph_mod = @import("graph_mod");

const testing = std.testing;
const props = graph_mod.properties_mod;
const page_ops = graph_mod.page_ops_mod;

const ctx_alloc: graph_mod.algorithms_context_mod.Context = .{ .allocator = testing.allocator };

fn initPropGraph() !graph_mod.Graph {
    return graph_mod.Graph.initWithOptions(testing.allocator, .{ .edge_properties = true });
}

test "properties: addEdgeWithProperties returns stable rows readable via lookup and columns" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const other_destination = try graph.addNode();

    const row_source_destination = try graph.addEdgeWithProperties(source, destination, 0, 0);
    const row_source_other = try graph.addEdgeWithProperties(source, other_destination, 0, 0);
    try testing.expect(row_source_destination != 0);
    try testing.expect(row_source_other != 0);
    try testing.expect(row_source_destination != row_source_other);

    try testing.expectEqual(@as(?u32, row_source_destination), try graph.edgePropertyRow(source, destination));
    try testing.expectEqual(@as(?u32, row_source_other), try graph.edgePropertyRow(source, other_destination));
    try testing.expectEqual(@as(?u32, null), try graph.edgePropertyRow(destination, source));

    var weights = props.EdgeColumn(f32).init(testing.allocator, 0.0);
    defer weights.deinit();
    try weights.set(row_source_destination, 1.5);
    try weights.set(row_source_other, 2.5);
    try testing.expectEqual(@as(f32, 1.5), weights.get(row_source_destination));
    try testing.expectEqual(@as(f32, 2.5), weights.get(row_source_other));
    try testing.expectEqual(@as(f32, 0.0), weights.get(999));

    try graph.validate();
}

test "properties: rows survive tiny promotion, block growth, and preventive repair" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [200]graph_mod.NodeId = undefined;
    var rows: [200]u32 = undefined;
    for (0..destinations.len) |destination_idx| destinations[destination_idx] = try graph.addNode();
    // Crosses the tiny cap (8) and multiple 64-edge blocks with tail COWs.
    for (0..destinations.len) |destination_idx| {
        rows[destination_idx] = try graph.addEdgeWithProperties(source, destinations[destination_idx], 0, 0);
    }
    for (0..destinations.len) |destination_idx| {
        try testing.expectEqual(@as(?u32, rows[destination_idx]), try graph.edgePropertyRow(source, destinations[destination_idx]));
    }

    // Preventive full rebuild must carry every row.
    _ = try graph.repairNode(source);
    for (0..destinations.len) |destination_idx| {
        try testing.expectEqual(@as(?u32, rows[destination_idx]), try graph.edgePropertyRow(source, destinations[destination_idx]));
    }
    try graph.validate();
}

test "properties: removed edge's row is retired and recycled after reclaim" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const source = try graph.addNode();
    const removed_destination = try graph.addNode();
    const recycled_destination = try graph.addNode();

    const recycled_row = try graph.addEdgeWithProperties(source, removed_destination, 0, 0);
    try testing.expect(try graph.removeEdge(source, removed_destination));
    try testing.expectEqual(@as(?u32, null), try graph.edgePropertyRow(source, removed_destination));

    graph.reclaimRetired();
    const reused_row = try graph.addEdgeWithProperties(source, recycled_destination, 0, 0);
    try testing.expectEqual(recycled_row, reused_row);
    try graph.validate();
}

test "properties: removeNode retires forward rows; tombstone repair retires predecessor rows" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const pred = try graph.addNode();
    const target = try graph.addNode();
    const other = try graph.addNode();

    const row_pt = try graph.addEdgeWithProperties(pred, target, 0, 0);
    const row_po = try graph.addEdgeWithProperties(pred, other, 0, 0);
    const row_to = try graph.addEdgeWithProperties(target, other, 0, 0);

    _ = try graph.removeNode(target);
    // The predecessor's surviving edge keeps its row through compaction.
    _ = try graph.repairNode(pred);
    try testing.expectEqual(@as(?u32, row_po), try graph.edgePropertyRow(pred, other));

    // Rows of (pred→target) and (target→other) are retired; after reclaim
    // they recycle (in some order) for the next edges.
    graph.reclaimRetired();
    const fresh = try graph.addNode();
    const recycled_a = try graph.addEdgeWithProperties(pred, fresh, 0, 0);
    const recycled_b = try graph.addEdgeWithProperties(other, fresh, 0, 0);
    const got_both = (recycled_a == row_pt and recycled_b == row_to) or (recycled_a == row_to and recycled_b == row_pt);
    try testing.expect(got_both);
    try graph.validate();
}

test "properties: addEdges batch assigns rows; snapshot outEdges exposes them" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [12]graph_mod.NodeId = undefined;
    for (0..destinations.len) |destination_idx| destinations[destination_idx] = try graph.addNode();

    var edge_inputs: [12]graph_mod.types_mod.EdgeInput = undefined;
    for (0..destinations.len) |destination_idx| edge_inputs[destination_idx] = .{ .destination = destinations[destination_idx] };
    _ = try graph.addEdges(source, &edge_inputs);

    var snapshot = try graph.snapshot(ctx_alloc);
    defer snapshot.deinit();
    var it = try snapshot.outEdges(source);
    var seen: usize = 0;
    var last_row: u32 = 0;
    while (it.next()) |edge| {
        try testing.expect(edge.property_row != 0);
        try testing.expect(edge.property_row != last_row);
        last_row = edge.property_row;
        seen += 1;
    }
    try testing.expectEqual(destinations.len, seen);
    try graph.validate();
}

test "properties: builder freeze assigns rows and CSR export aligns them" {
    var builder = try graph_mod.GraphBuilder.initWithOptions(testing.allocator, .{ .edge_properties = true });
    defer builder.deinit();

    const source = try builder.addNode();
    const destination = try builder.addNode();
    const other_destination = try builder.addNode();
    try builder.addEdge(source, destination, 7, 0);
    try builder.addEdge(source, other_destination, 8, 0);
    try builder.addEdge(destination, other_destination, 9, 0);

    var graph = try builder.freeze();
    defer graph.deinit();

    const row_source_destination = (try graph.edgePropertyRow(source, destination)) orelse return error.TestExpectedEqual;
    const row_source_other = (try graph.edgePropertyRow(source, other_destination)) orelse return error.TestExpectedEqual;
    const row_destination_other = (try graph.edgePropertyRow(destination, other_destination)) orelse return error.TestExpectedEqual;
    try testing.expect(row_source_destination != row_source_other and row_source_other != row_destination_other and row_source_destination != row_destination_other);

    var weights = props.EdgeColumn(u64).init(testing.allocator, 0);
    defer weights.deinit();
    try weights.set(row_source_destination, 70);
    try weights.set(row_source_other, 80);
    try weights.set(row_destination_other, 90);

    var csr = blk: {
        var snapshot = try graph.snapshot(ctx_alloc);
        defer snapshot.deinit();
        break :blk try snapshot.materializeCsr(ctx_alloc);
    };
    defer csr.deinit(testing.allocator);

    const out_rows = csr.out_rows orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u64, 3), csr.edgeCount());
    // Every (source, target, row) triple in the CSR maps back to the column.
    for (0..csr.nodeCount()) |node_idx| {
        const node: graph_mod.NodeId = .{ .index = @intCast(node_idx) };
        if (!csr.isLive(node)) continue;
        const start: usize = @intCast(csr.out_offsets[node_idx]);
        const end: usize = @intCast(csr.out_offsets[node_idx + 1]);
        for (start..end) |edge_idx| {
            const expected: u64 = switch (node_idx) {
                0 => if (csr.out_targets[edge_idx] == destination.index) @as(u64, 70) else 80,
                1 => 90,
                else => unreachable,
            };
            try testing.expectEqual(expected, weights.get(out_rows[edge_idx]));
        }
    }
    try graph.validate();
}

test "properties: multigraph + properties give parallel edges distinct rows" {
    var graph = try graph_mod.Graph.initWithOptions(testing.allocator, .{ .multigraph = true, .edge_properties = true });
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const row_1 = try graph.addEdgeWithProperties(source, destination, 0, 0);
    const row_2 = try graph.addEdgeWithProperties(source, destination, 0, 0);
    try testing.expect(row_1 != row_2);

    var it = try graph.outEdges(source);
    defer it.deinit();
    var rows_seen: [2]u32 = .{ 0, 0 };
    var count: usize = 0;
    while (it.next()) |edge| : (count += 1) rows_seen[count] = edge.property_row;
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect((rows_seen[0] == row_1 and rows_seen[1] == row_2) or (rows_seen[0] == row_2 and rows_seen[1] == row_1));
    try graph.validate();
}

test "properties: disabled mode rejects property APIs and pays no sidecar" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    try testing.expectError(error.UnsupportedOperation, graph.addEdgeWithProperties(source, destination, 0, 0));
    try testing.expectError(error.UnsupportedOperation, graph.edgePropertyRow(source, destination));
    try graph.validate();
}

fn containsViolation(violations: []const graph_mod.types_mod.Violation, comptime tag: anytype) bool {
    for (violations) |violation| {
        if (violation == tag) return true;
    }
    return false;
}

test "properties: PropertyGraph writes every field on addEdge — recycled rows never leak values" {
    const Schema = struct { weight: f32 = 0.0, since: u64 = 0 };
    var pg = try props.PropertyGraph(Schema).init(testing.allocator, .{});
    defer pg.deinit();

    const source = try pg.addNode();
    const destination = try pg.addNode();
    const other_destination = try pg.addNode();

    const row_source_destination = try pg.addEdge(source, destination, 0, .{}, .{ .weight = 1.5, .since = 1111 });
    const source_destination_values = (try pg.edgeValues(source, destination)) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(f32, 1.5), source_destination_values.weight);
    try testing.expectEqual(@as(u64, 1111), source_destination_values.since);

    // Remove + reclaim recycles the row; the wrapper overwrites all fields,
    // so the recycled row carries the NEW edge's values, never the old ones.
    try testing.expect(try pg.removeEdge(source, destination));
    pg.graph.reclaimRetired();
    const row_source_other = try pg.addEdge(source, other_destination, 0, .{}, .{ .weight = 9.0, .since = 2222 });
    try testing.expectEqual(row_source_destination, row_source_other);
    const source_other_values = (try pg.edgeValues(source, other_destination)) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(f32, 9.0), source_other_values.weight);
    try testing.expectEqual(@as(u64, 2222), source_other_values.since);

    // Direct column access for bulk scans.
    try testing.expectEqual(@as(f32, 9.0), pg.column("weight").get(row_source_other));
}

test "properties: validate detects out-of-range rows; debugValidate detects duplicates" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [12]graph_mod.NodeId = undefined;
    for (0..destinations.len) |destination_idx| {
        destinations[destination_idx] = try graph.addNode();
        _ = try graph.addEdgeWithProperties(source, destinations[destination_idx], 0, 0);
    }
    try graph.validate();

    // 12 edges → block mode, single contiguous block.
    const adjacency = try graph.publishedNodeAdj(source);
    const block_idx = adjacency.first_block_fwd;
    const prop_block = page_ops.edgeBlockFwdPropsAt(&graph.graph, block_idx);

    // Out-of-range row: fast validate fails, debugValidate reports it.
    const saved = prop_block.rows[3];
    prop_block.rows[3] = 0;
    try testing.expectError(error.CorruptGraph, graph.validate());
    {
        const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
        defer testing.allocator.free(violations);
        try testing.expect(containsViolation(violations, .invalid_prop_row));
    }
    prop_block.rows[3] = saved;
    try graph.validate();

    // Duplicate row across two entries: debug-only (needs the global map).
    const saved_dup = prop_block.rows[5];
    prop_block.rows[5] = prop_block.rows[4];
    {
        const violations = try graph.debugValidate(.{ .allocator = testing.allocator });
        defer testing.allocator.free(violations);
        try testing.expect(containsViolation(violations, .duplicate_prop_row));
    }
    prop_block.rows[5] = saved_dup;
    try graph.validate();
}

test "csr: direct live export matches snapshot export (tombstones + rows)" {
    var graph = try initPropGraph();
    defer graph.deinit();

    const hub = try graph.addNode();
    var destinations: [40]graph_mod.NodeId = undefined;
    for (0..destinations.len) |destination_idx| {
        destinations[destination_idx] = try graph.addNode();
        _ = try graph.addEdgeWithProperties(hub, destinations[destination_idx], 0, 0);
    }
    _ = try graph.addEdgeWithProperties(destinations[0], destinations[1], 0, 0);
    // Tombstones on the hub's forward side.
    _ = try graph.removeNode(destinations[5]);
    _ = try graph.removeNode(destinations[6]);

    const ctx: graph_mod.algorithms_context_mod.Context = .{ .allocator = testing.allocator };
    var via_snapshot = blk: {
        var snapshot = try graph.snapshot(ctx);
        defer snapshot.deinit();
        break :blk try snapshot.materializeCsr(ctx);
    };
    defer via_snapshot.deinit(testing.allocator);
    var direct = try graph.materializeCsr(ctx);
    defer direct.deinit(testing.allocator);

    try testing.expectEqual(via_snapshot.node_count, direct.node_count);
    try testing.expectEqualSlices(u64, via_snapshot.out_offsets, direct.out_offsets);
    try testing.expectEqualSlices(u32, via_snapshot.out_targets, direct.out_targets);
    try testing.expectEqualSlices(u64, via_snapshot.alive_node_bitmap, direct.alive_node_bitmap);
    try testing.expectEqualSlices(u32, via_snapshot.out_rows.?, direct.out_rows.?);
}
