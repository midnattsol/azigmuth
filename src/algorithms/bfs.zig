const std = @import("std");
const graph = @import("../graph.zig");
const utils = @import("../utils.zig");

pub fn bfs(g: anytype, start: graph.NodeId, allocator: std.mem.Allocator) ![]graph.NodeId {
    comptime utils.requireNeighborsAndNodeCount(@TypeOf(g));
    try utils.validateNode(g, start);

    const node_count = g.nodeCount();
    var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
    defer visited.deinit(allocator);

    var queue = try std.ArrayList(graph.NodeId).initCapacity(allocator, node_count);
    defer queue.deinit(allocator);
    var order: std.ArrayList(graph.NodeId) = .empty;
    errdefer order.deinit(allocator);

    visited.set(start.index);
    try queue.append(allocator, start);
    try order.append(allocator, start);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        {
            var iter = try g.neighbors(current);
            defer iter.deinit();
            while (iter.next()) |neighbor| {
                if (!visited.isSet(neighbor.index)) {
                    visited.set(neighbor.index);
                    try queue.append(allocator, neighbor);
                    try order.append(allocator, neighbor);
                }
            }
        }
    }
    return order.toOwnedSlice(allocator);
}

fn idxOf(order: []const graph.NodeId, target: usize) usize {
    for (order, 0..) |n, i| if (n.index == target) return i;
    unreachable;
}

test "bfs order on a simple graph" {
    var g = try utils.buildTestGraph(std.testing.allocator, 5, &.{
        .{ 0, 1 }, .{ 0, 2 }, .{ 1, 3 }, .{ 2, 4 },
    });
    defer g.deinit();

    const order = try bfs(g, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0), order[0].index);
    try std.testing.expect(idxOf(order, 1) < idxOf(order, 3));
    try std.testing.expect(idxOf(order, 2) < idxOf(order, 4));
}

test "bfs distances" {
    var g = try utils.buildTestGraph(std.testing.allocator, 4, &.{
        .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 }, .{ 2, 3 },
    });
    defer g.deinit();

    const order = try bfs(g, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expect(idxOf(order, 1) < idxOf(order, 3));
    try std.testing.expect(idxOf(order, 2) < idxOf(order, 3));
}

test "bfs on unconnected graph visits only reachable component" {
    var g = try utils.buildTestGraph(std.testing.allocator, 4, &.{
        .{ 0, 1 }, .{ 2, 3 },
    });
    defer g.deinit();

    const order = try bfs(g, .{ .index = 0 }, std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0].index == 0 and order[1].index == 1);
}

test "bfs returns error on invalid start node" {
    var g = try utils.buildTestGraph(std.testing.allocator, 1, &.{});
    defer g.deinit();

    try std.testing.expectError(error.InvalidNode, bfs(g, .{ .index = 99 }, std.testing.allocator));
}
