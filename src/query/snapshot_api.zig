const std = @import("std");
const graph_core = @import("../core/graph_core.zig");
const rcu = @import("../concurrency/rcu.zig");
const read_session = @import("read_session.zig");
const snapshot_view = @import("snapshot_view.zig");
const snapshot_mod = @import("../algorithms/snapshot.zig");

pub const ReadSession = read_session.ReadSession;
pub const ReadSnapshot = snapshot_mod.ReadSnapshot;
pub const SnapshotNeighborIterator = snapshot_view.SnapshotNeighborIterator;
pub const SnapshotOutEdgeIterator = snapshot_view.SnapshotOutEdgeIterator;

/// Enters the read side of the graph and returns a reusable read session.
pub fn beginReadSession(core: *graph_core.GraphCore) !ReadSession {
    const reader_token = try rcu.readerEnter(core);
    return ReadSession.init(core, reader_token);
}

/// Captures a caller-owned snapshot backed by one read session.
pub fn snapshot(core: *graph_core.GraphCore, ctx: anytype) !ReadSnapshot {
    var read = try beginReadSession(core);
    errdefer read.deinit();
    return snapshot_mod.ReadSnapshot.init(read, ctx.allocator);
}
