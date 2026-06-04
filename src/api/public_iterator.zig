//! Public `NeighborIterator` — returned by value by `neighbors()` and
//! `inNeighbors()`.  Does not allocate on creation; only holds an RCU reader
//! token that must be released via `deinit()`.
//!
//! Key semantics:
//!   - `deinit()` is idempotent — double-`deinit` is safe.
//!   - `materialize()` drains remaining items into a caller-owned slice but
//!     **does not consume the iterator** — `deinit()` is still required.
//!   - After `materialize()`, `next()` returns `null` (the iterator is
//!     logically exhausted).

const std = @import("std");
const internal = @import("../graph.zig");

pub const NeighborIterator = struct {
    inner: internal.NeighborIterator,

    /// Returns the next neighbor, or `null` if exhausted.  Removed nodes are
    /// automatically skipped.
    pub fn next(self: *NeighborIterator) ?internal.NodeId {
        return self.inner.next();
    }

    /// Releases the RCU reader token.  Does NOT free heap memory (the iterator
    /// is a value type).  Idempotent — safe to call multiple times.
    pub fn deinit(self: *NeighborIterator) void {
        self.inner.deinit();
    }

    /// Drains remaining items into a caller-owned slice.  Allocates the result
    /// via `allocator`; the caller must free it.
    ///
    /// The iterator is exhausted after this call (`next()` returns `null`), but
    /// `deinit()` is still required to release the RCU reader token.
    /// `materialize()` does **not** consume the iterator.
    pub fn materialize(self: *NeighborIterator, allocator: std.mem.Allocator) internal.GraphError![]internal.NodeId {
        var out = try std.ArrayList(internal.NodeId).initCapacity(allocator, self.inner.snapshotDegree());
        errdefer out.deinit(allocator);
        while (self.inner.next()) |neighbor| {
            try out.append(allocator, neighbor);
        }
        return out.toOwnedSlice(allocator);
    }
};
