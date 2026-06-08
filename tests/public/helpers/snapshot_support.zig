const std = @import("std");
const graphz = @import("graphz");

pub const SnapshotNeighbors = struct {
    snapshot: ?*graphz.ReadSnapshot,
    iterator: graphz.SnapshotNeighborIterator,

    pub fn next(self: *SnapshotNeighbors) ?graphz.NodeId {
        return self.iterator.next();
    }

    pub fn materialize(self: *SnapshotNeighbors, allocator: std.mem.Allocator) ![]graphz.NodeId {
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
    snapshot: ?*graphz.ReadSnapshot,
    iterator: graphz.SnapshotOutEdgeIterator,

    pub fn next(self: *SnapshotOutEdges) ?graphz.EdgeRef {
        return self.iterator.next();
    }

    pub fn deinit(self: *SnapshotOutEdges) void {
        if (self.snapshot) |snapshot| {
            snapshot.deinit();
            self.snapshot = null;
        }
    }
};

pub fn neighbors(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !SnapshotNeighbors {
    var snapshot = try graph.snapshot(allocator);
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.neighbors(node) };
}

pub fn inNeighbors(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !SnapshotNeighbors {
    var snapshot = try graph.snapshot(allocator);
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.inNeighbors(node) };
}

pub fn outEdges(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !SnapshotOutEdges {
    var snapshot = try graph.snapshot(allocator);
    errdefer snapshot.deinit();
    return .{ .snapshot = snapshot, .iterator = try snapshot.outEdges(node) };
}

pub fn outDegree(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !usize {
    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();
    return snapshot.outDegree(node);
}

pub fn inDegree(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !usize {
    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();
    return snapshot.inDegree(node);
}

pub fn neighborsMaterialized(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) ![]graphz.NodeId {
    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();
    return snapshot.neighborsMaterialized(node, allocator);
}

pub fn inNeighborsMaterialized(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) ![]graphz.NodeId {
    var snapshot = try graph.snapshot(allocator);
    defer snapshot.deinit();
    return snapshot.inNeighborsMaterialized(node, allocator);
}
