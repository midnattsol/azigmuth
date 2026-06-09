const std = @import("std");
const Io = std.Io;

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool),

    pub fn init() CancelToken {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?Io = null,
    parallel_min_nodes: usize = 1024,
    cancel_token: ?*CancelToken = null,
};
