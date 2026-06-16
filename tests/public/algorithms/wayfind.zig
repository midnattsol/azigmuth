const std = @import("std");
const az = @import("azigmuth");

const testing = std.testing;
const Wayfind = az.Wayfind;
const ctx = az.Context{ .allocator = testing.allocator };

const Fixture = struct {
    graph: *az.Graph,
    nodes: [5]az.NodeId,

    fn init() !Fixture {
        var graph = try az.Graph.init(testing.allocator);
        errdefer graph.deinit();

        var nodes: [5]az.NodeId = undefined;
        for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

        try graph.addEdge(nodes[0], nodes[1], 1, .{});
        try graph.addEdge(nodes[1], nodes[2], 1, .{});
        try graph.addEdge(nodes[0], nodes[3], 2, .{});
        try graph.addEdge(nodes[3], nodes[4], 1, .{});
        return .{ .graph = graph, .nodes = nodes };
    }

    fn deinit(self: *Fixture) void {
        self.graph.deinit();
    }
};

test "wayfind: public builder plan executes against ReadSnapshot" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    const seeds = [_]u32{fixture.nodes[0].index};
    const blocked = [_]u32{fixture.nodes[2].index};
    const plan = comptime Wayfind.Query.fromParam(0)
        .out(1, .{ .min = 1, .max = 2 })
        .minusParam(1)
        .ids();

    var result = try snapshot.wayfind(plan, ctx, .{ .sets = &.{ &seeds, &blocked } });
    defer result.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &.{fixture.nodes[1].index}, result.ids);
}

test "wayfind: public parser binds parameter names and executes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var snapshot = try fixture.graph.snapshot(ctx);
    defer snapshot.deinit();

    var parsed = try Wayfind.parse(
        testing.allocator,
        "from $seeds | out(follows){1..2} | - $blocked | count",
        &.{.{ .name = "follows", .value = 1 }},
    );
    defer parsed.deinit(testing.allocator);

    const seeds = [_]u32{fixture.nodes[0].index};
    const blocked = [_]u32{fixture.nodes[2].index};
    var sets: [2][]const u32 = undefined;
    sets[parsed.paramSlot("seeds").?] = &seeds;
    sets[parsed.paramSlot("blocked").?] = &blocked;

    var result = try snapshot.wayfind(parsed.plan(), ctx, .{ .sets = &sets });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 1), result.count);
}

test "wayfind: public edge and csr terminals expose owned results" {
    var graph = try az.Graph.initWithOptions(testing.allocator, .{ .edge_properties = true });
    defer graph.deinit();

    var nodes: [3]az.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();
    const row_01 = try graph.addEdgeWithProperties(nodes[0], nodes[1], 1, .{});
    const row_12 = try graph.addEdgeWithProperties(nodes[1], nodes[2], 1, .{});

    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    const members = [_]u32{ nodes[0].index, nodes[1].index, nodes[2].index };
    const edges_plan = comptime Wayfind.Query.fromParam(0).edges();
    var edges = try snapshot.wayfind(edges_plan, ctx, .{ .sets = &.{&members} });
    defer edges.deinit(testing.allocator);

    try testing.expectEqualSlices(Wayfind.EdgeRow, &.{
        .{ .source = nodes[0].index, .destination = nodes[1].index, .prop_row = row_01 },
        .{ .source = nodes[1].index, .destination = nodes[2].index, .prop_row = row_12 },
    }, edges.edges);

    const csr_plan = comptime Wayfind.Query.fromParam(0).csr();
    var csr_result = try snapshot.wayfind(csr_plan, ctx, .{ .sets = &.{&members} });
    defer csr_result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 2), csr_result.csr.edgeCount());
    try testing.expectEqualSlices(u32, &.{nodes[1].index}, try csr_result.csr.outNeighbors(nodes[0]));
    try testing.expectEqualSlices(u32, &.{nodes[2].index}, try csr_result.csr.outNeighbors(nodes[1]));
}

test "wayfind: removed param ids are stale but removed seeds are errors" {
    var graph = try az.Graph.init(testing.allocator);
    defer graph.deinit();

    const live = try graph.addNode();
    const removed = try graph.addNode();
    _ = try graph.removeNode(removed);

    var snapshot = try graph.snapshot(ctx);
    defer snapshot.deinit();

    const params = [_]u32{ live.index, removed.index };
    const param_plan = comptime Wayfind.Query.fromParam(0).ids();
    var live_only = try snapshot.wayfind(param_plan, ctx, .{ .sets = &.{&params} });
    defer live_only.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{live.index}, live_only.ids);

    const seed_plan = comptime Wayfind.Query.fromNode(1).ids();
    try testing.expectError(error.InvalidNode, snapshot.wayfind(seed_plan, ctx, .{}));
}
