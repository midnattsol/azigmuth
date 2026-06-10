const std = @import("std");
const node_hot = @import("hot.zig");

// Default packed-vs-isolated benchmark setting for NodeHot pages.
// Switch to 64 to isolate one hot slot per cache line.
pub const SLOT_BYTES: usize = 32;

pub const Slot = extern struct {
    hot: node_hot.NodeHot = .{},
    _padding: [SLOT_BYTES - @sizeOf(node_hot.NodeHot)]u8 = [_]u8{0} ** (SLOT_BYTES - @sizeOf(node_hot.NodeHot)),

    pub fn node(self: *Slot) *node_hot.NodeHot {
        return &self.hot;
    }

    pub fn nodeConst(self: *const Slot) *const node_hot.NodeHot {
        return &self.hot;
    }
};

comptime {
    std.debug.assert(SLOT_BYTES >= @sizeOf(node_hot.NodeHot));
    std.debug.assert((SLOT_BYTES == 32) or (SLOT_BYTES == 64));
    std.debug.assert(@sizeOf(Slot) == SLOT_BYTES);
}
