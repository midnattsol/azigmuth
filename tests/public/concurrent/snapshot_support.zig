const std = @import("std");
const graphz = @import("graphz");

pub const SnapshotNeighbors = struct {
    snapshot: ?*graphz.ReadSnapshot,
    iterator: graphz.SnapshotNeighborIterator,

    pub fn next(self: *SnapshotNeighbors) ?graphz.NodeId { return self.iterator.next(); }
    pub fn materialize(self: *SnapshotNeighbors, allocator: std.mem.Allocator) ![]graphz.NodeId { return self.iterator.materialize(allocator); }
    pub fn deinit(self: *SnapshotNeighbors) void { if (self.snapshot) |snapshot| { snapshot.deinit(); self.snapshot = null; } }
};

pub fn neighbors(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !SnapshotNeighbors { var snapshot = try graph.snapshot(allocator); errdefer snapshot.deinit(); return .{ .snapshot = snapshot, .iterator = try snapshot.neighbors(node) }; }
