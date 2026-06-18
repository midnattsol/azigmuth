const std = @import("std");
const node_mutation_control = @import("mutation_control.zig");

// Default packed-vs-isolated benchmark setting for NodeMutationControl pages.
// Switch to 64 to isolate one hot slot per cache line.
pub const SLOT_BYTES: usize = 32;

pub const Slot = extern struct {
    control: node_mutation_control.NodeMutationControl = .{},
    _padding: [SLOT_BYTES - @sizeOf(node_mutation_control.NodeMutationControl)]u8 = [_]u8{0} ** (SLOT_BYTES - @sizeOf(node_mutation_control.NodeMutationControl)),

    pub fn node(self: *Slot) *node_mutation_control.NodeMutationControl {
        return &self.control;
    }

    pub fn nodeConst(self: *const Slot) *const node_mutation_control.NodeMutationControl {
        return &self.control;
    }
};

comptime {
    std.debug.assert(SLOT_BYTES >= @sizeOf(node_mutation_control.NodeMutationControl));
    std.debug.assert((SLOT_BYTES == 32) or (SLOT_BYTES == 64));
    std.debug.assert(@sizeOf(Slot) == SLOT_BYTES);
}
