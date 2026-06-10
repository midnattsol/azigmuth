const std = @import("std");
const types = @import("../../core/types.zig");

pub const NodeMeta = extern struct {
    published_meta: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(types.PublishedMeta{})),

    pub fn loadPublishedMeta(self: *const NodeMeta) types.PublishedMeta {
        return @bitCast(self.published_meta.load(.acquire));
    }

    pub fn storePublishedMeta(self: *NodeMeta, meta: types.PublishedMeta) void {
        self.published_meta.store(@bitCast(meta), .release);
    }

    pub fn cmpxchgPublishedMeta(self: *NodeMeta, expected: types.PublishedMeta, desired: types.PublishedMeta) ?types.PublishedMeta {
        const actual = self.published_meta.cmpxchgStrong(@bitCast(expected), @bitCast(desired), .acq_rel, .acquire);
        return if (actual) |raw| @as(types.PublishedMeta, @bitCast(raw)) else null;
    }
};

comptime {
    if (@offsetOf(types.NodeBuffer, "published_meta") != 0) {
        @compileError("NodeMeta must alias NodeBuffer at offset 0");
    }
    if (@sizeOf(NodeMeta) != @sizeOf(std.atomic.Value(u64))) {
        @compileError("NodeMeta must contain only the published_meta word");
    }
}
