const std = @import("std");
const internal = @import("../graph.zig");

pub const NeighborIterator = struct {
    inner: internal.NeighborIterator,

    pub fn next(self: *NeighborIterator) ?internal.NodeId {
        return self.inner.next();
    }

    pub fn deinit(self: *NeighborIterator) void {
        self.inner.deinit();
    }

    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        var out = try std.ArrayList(internal.NodeId).initCapacity(allocator, self.inner.snapshotDegree());
        while (self.inner.next()) |neighbor| {
            out.appendAssumeCapacity(neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};
