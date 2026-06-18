//! Public `GraphBuilder` handle — heap-allocated opaque type for bulk graph
//! construction. `freeze()` sorts the accumulated edges into a compact,
//! read-optimized layout.
//!
//! Lifetime:
//!   1. `init(allocator)` returns a `*GraphBuilder`.
//!   2. Add nodes and edges via `addNode()` and `addEdge()`.
//!   3. `freeze()` compacts the builder's edges into a read-optimized `*Graph`
//!      and transfers ownership.  After `freeze()`, the builder becomes
//!      **inert** — `addNode()`, `addEdge()`, and `freeze()` return
//!      `error.UnsupportedOperation`, while `deinit()` remains valid.
//!   4. `deinit()` releases the builder's scratch resources *and* the heap
//!      handle.  Must be called regardless of whether `freeze()` succeeded.
//!   5. The returned `*Graph` from `freeze()` is a normal mutable `Graph` whose
//!      lifetime is independent of the builder — call `graph.deinit()` when
//!      done with it.

const std = @import("std");
const internal = @import("../graph.zig");
const internal_builder = @import("../internal/builder.zig");
const public_graph = @import("public_graph.zig");

pub const GraphBuilder = opaque {
    fn inner(self: *GraphBuilder) *internal_builder.GraphBuilder {
        return @ptrCast(@alignCast(self));
    }

    /// Creates a new builder backed by `allocator`.  The caller owns the
    /// returned `*GraphBuilder` and must call `deinit()` when done, regardless
    /// of whether `freeze()` was called.
    pub fn init(allocator: std.mem.Allocator) internal.GraphError!*GraphBuilder {
        const builder_handle = try allocator.create(internal_builder.GraphBuilder);
        errdefer allocator.destroy(builder_handle);
        builder_handle.* = try internal_builder.GraphBuilder.init(allocator);
        return @ptrCast(builder_handle);
    }

    /// Creates a new builder with the given options.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: internal.GraphOptions) internal.GraphError!*GraphBuilder {
        const builder_handle = try allocator.create(internal_builder.GraphBuilder);
        errdefer allocator.destroy(builder_handle);
        builder_handle.* = try internal_builder.GraphBuilder.initWithOptions(allocator, options);
        return @ptrCast(builder_handle);
    }

    /// Frees builder scratch resources and the heap handle.  If `freeze()` was
    /// not called, the internal working graph is also released.  Must be called
    /// even after a successful `freeze()` — the builder handle is always owned
    /// by the caller.
    pub fn deinit(self: *GraphBuilder) void {
        const builder_handle = self.inner();
        const allocator = builder_handle.graph.graph.allocator;
        builder_handle.deinit();
        allocator.destroy(builder_handle);
    }

    pub fn addNode(self: *GraphBuilder) internal.GraphError!internal.NodeId {
        return self.inner().addNode();
    }

    pub fn addEdge(self: *GraphBuilder, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!void {
        return self.inner().addEdge(source, destination, relation, @bitCast(flags));
    }

    /// Compacts the builder's nodes and edges into a read-optimized `*Graph`
    /// and transfers ownership to the caller.  The builder becomes inert after
    /// this call — mutating calls return `error.UnsupportedOperation`, while
    /// `deinit()` remains valid.  The returned `*Graph` is a normal mutable
    /// `Graph` with its own independent lifetime.
    pub fn freeze(self: *GraphBuilder) internal.GraphError!*public_graph.Graph {
        const builder_handle = self.inner();
        const allocator = builder_handle.graph.graph.allocator;
        const graph_handle = try allocator.create(internal.Graph);
        errdefer allocator.destroy(graph_handle);
        const frozen = try builder_handle.freeze();
        graph_handle.* = frozen;
        return @ptrCast(graph_handle);
    }
};
