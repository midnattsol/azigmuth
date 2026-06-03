const std = @import("std");
const internal = @import("../graph.zig");
const public_graph = @import("public_graph.zig");

pub const GraphBuilder = opaque {
    pub fn init(allocator: std.mem.Allocator) !*GraphBuilder {
        const b = try allocator.create(internal.GraphBuilder);
        errdefer allocator.destroy(b);
        b.* = try internal.GraphBuilder.init(allocator);
        return @ptrCast(b);
    }

    pub fn deinit(self: *GraphBuilder) void {
        const b: *internal.GraphBuilder = @ptrCast(@alignCast(self));
        const alloc = b.graph.graph.allocator;
        b.deinit();
        alloc.destroy(b);
    }

    pub fn addNode(self: *GraphBuilder) !internal.NodeId {
        const b: *internal.GraphBuilder = @ptrCast(@alignCast(self));
        return b.addNode();
    }

    pub fn addEdge(self: *GraphBuilder, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!void {
        const b: *internal.GraphBuilder = @ptrCast(@alignCast(self));
        return b.addEdge(source, destination, relation, @bitCast(flags));
    }

    pub fn freeze(self: *GraphBuilder) internal.GraphError!*public_graph.Graph {
        const b: *internal.GraphBuilder = @ptrCast(@alignCast(self));
        const frozen = try b.freeze();
        const alloc = frozen.graph.allocator;
        const g = try alloc.create(internal.Graph);
        g.* = frozen;
        return @ptrCast(g);
    }
};
