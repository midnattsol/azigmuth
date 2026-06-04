//! Public `GraphBuilder` handle — heap-allocated opaque type for bulk graph
//! construction from sorted edge batches.
//!
//! Lifetime:
//!   1. `init(allocator)` returns a `*GraphBuilder`.
//!   2. Add nodes and edges via `addNode()` and `addEdge()`.
//!   3. `freeze()` compacts the builder's edges into a read-optimized `*Graph`
//!      and transfers ownership.  After `freeze()`, the builder becomes
//!      **inert** — only `deinit()` remains valid.
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
    /// Creates a new builder backed by `allocator`.  The caller owns the
    /// returned `*GraphBuilder` and must call `deinit()` when done, regardless
    /// of whether `freeze()` was called.
    pub fn init(allocator: std.mem.Allocator) internal.GraphError!*GraphBuilder {
        const b = try allocator.create(internal_builder.GraphBuilder);
        errdefer allocator.destroy(b);
        b.* = try internal_builder.GraphBuilder.init(allocator);
        return @ptrCast(b);
    }

    /// Frees builder scratch resources and the heap handle.  If `freeze()` was
    /// not called, the internal working graph is also released.  Must be called
    /// even after a successful `freeze()` — the builder handle is always owned
    /// by the caller.
    pub fn deinit(self: *GraphBuilder) void {
        const b: *internal_builder.GraphBuilder = @ptrCast(@alignCast(self));
        const alloc = b.graph.graph.allocator;
        b.deinit();
        alloc.destroy(b);
    }

    pub fn addNode(self: *GraphBuilder) internal.GraphError!internal.NodeId {
        const b: *internal_builder.GraphBuilder = @ptrCast(@alignCast(self));
        return b.addNode();
    }

    pub fn addEdge(self: *GraphBuilder, source: internal.NodeId, destination: internal.NodeId, relation: u16, flags: internal.EdgeFlags) internal.GraphError!void {
        const b: *internal_builder.GraphBuilder = @ptrCast(@alignCast(self));
        return b.addEdge(source, destination, relation, @bitCast(flags));
    }

    /// Compacts the builder's nodes and edges into a read-optimized `*Graph`
    /// and transfers ownership to the caller.  The builder becomes inert after
    /// this call — only `deinit()` remains valid.  The returned `*Graph` is a
    /// normal mutable `Graph` with its own independent lifetime.
    pub fn freeze(self: *GraphBuilder) internal.GraphError!*public_graph.Graph {
        const b: *internal_builder.GraphBuilder = @ptrCast(@alignCast(self));
        const alloc = b.graph.graph.allocator;
        const g = try alloc.create(internal.Graph);
        errdefer alloc.destroy(g);
        const frozen = try b.freeze();
        g.* = frozen;
        return @ptrCast(g);
    }
};
