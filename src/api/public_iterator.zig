const std = @import("std");
const internal = @import("../graph.zig");

const IteratorImpl = struct {
    iter: internal.NeighborIterator,
    graph_allocator: std.mem.Allocator,
};

pub const NeighborIterator = opaque {
    pub fn next(self: *NeighborIterator) ?internal.NodeId {
        const impl: *IteratorImpl = @ptrCast(@alignCast(self));
        return impl.iter.next();
    }

    pub fn deinit(self: *NeighborIterator) void {
        const impl: *IteratorImpl = @ptrCast(@alignCast(self));
        impl.iter.deinit();
        impl.graph_allocator.destroy(impl);
    }

    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        const impl: *IteratorImpl = @ptrCast(@alignCast(self));
        const result = try impl.iter.materialize(allocator);
        impl.graph_allocator.destroy(impl);
        return result;
    }
};

pub fn newNeighborIterator(graph_allocator: std.mem.Allocator, internal_iter: internal.NeighborIterator) !*NeighborIterator {
    const impl = try graph_allocator.create(IteratorImpl);
    errdefer graph_allocator.destroy(impl);
    impl.* = .{ .iter = internal_iter, .graph_allocator = graph_allocator };
    return @ptrCast(impl);
}
