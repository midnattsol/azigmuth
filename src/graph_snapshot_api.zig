const std = @import("std");
const graph_core = @import("core/graph_core.zig");
const rcu = @import("rcu.zig");
const read_session = @import("query/read_session.zig");
const snapshot_mod = @import("algorithms/snapshot.zig");

pub const ReadSession = read_session.ReadSession;
pub const ReadSnapshot = snapshot_mod.ReadSnapshot;

pub fn beginReadSession(core: *graph_core.GraphCore) !ReadSession {
    const reader_token = try rcu.readerEnter(core);
    return ReadSession.init(core, reader_token);
}

pub fn snapshot(core: *graph_core.GraphCore, allocator: std.mem.Allocator) !ReadSnapshot {
    var read = try beginReadSession(core);
    errdefer read.deinit();
    return snapshot_mod.ReadSnapshot.init(read, allocator);
}
