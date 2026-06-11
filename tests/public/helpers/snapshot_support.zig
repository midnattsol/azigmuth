const std = @import("std");
const azigmuth = @import("azigmuth");

pub const SnapshotNeighbors = struct {
    snapshot: ?*azigmuth.ReadSnapshot,
    iterator: azigmuth.SnapshotNeighborIterator,

    pub fn next(self: *SnapshotNeighbors) ?azigmuth.NodeId {
        return self.iterator.next();
    }

    pub fn materialize(self: *SnapshotNeighbors, allocator: std.mem.Allocator) ![]azigmuth.NodeId {
        return self.iterator.materialize(allocator);
    }

    pub fn deinit(self: *SnapshotNeighbors) void {
        if (self.snapshot) |snapshot| {
            snapshot.deinit();
            self.snapshot = null;
        }
    }
};

pub const SnapshotOutEdges = struct {
    snapshot: ?*azigmuth.ReadSnapshot,
    iterator: azigmuth.SnapshotOutEdgeIterator,

    pub fn next(self: *SnapshotOutEdges) ?azigmuth.EdgeRef {
        return self.iterator.next();
    }

    pub fn deinit(self: *SnapshotOutEdges) void {
        if (self.snapshot) |snapshot| {
            snapshot.deinit();
            self.snapshot = null;
        }
    }
};

pub fn neighbors(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) !SnapshotNeighbors {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.neighbors(node) };
}

pub fn inNeighbors(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) !SnapshotNeighbors {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.inNeighbors(node) };
}

pub fn outEdges(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) !SnapshotOutEdges {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.outEdges(node) };
}

pub fn outDegree(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) !usize {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.outDegree(node);
}

pub fn inDegree(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) !usize {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.inDegree(node);
}

pub fn neighborsMaterialized(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) ![]azigmuth.NodeId {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.neighborsMaterialized(node, .{ .allocator = allocator });
}

pub fn inNeighborsMaterialized(graph: *azigmuth.Graph, node: azigmuth.NodeId, allocator: std.mem.Allocator) ![]azigmuth.NodeId {
    var snapshot = try graph.snapshot(.{ .allocator = allocator });
    defer snapshot.deinit();
    return snapshot.inNeighborsMaterialized(node, .{ .allocator = allocator });
}
