//! Intrusive lock-free stacks of storage indices.
//!
//! The stack node link lives in `types.ReclamationEntry.next`; the atomic head stores
//! the index in the low 32 bits and an ABA tag in the high 32 bits.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");

pub const EMPTY_INDEX: u32 = constants.END_OF_CHAIN;
pub const StackKind = enum { free, retired };

pub fn packHead(index: u32, tag: u32) u64 {
    return (@as(u64, tag) << 32) | @as(u64, index);
}

pub fn headIndex(head: u64) u32 {
    return @truncate(head);
}

pub fn headTag(head: u64) u32 {
    return @truncate(head >> 32);
}

pub fn reclamationNext(entry: *const types.ReclamationEntry) u32 {
    return entry.next.load(.acquire);
}

/// Walks an index chain that the caller already owns.
///
/// `next` is loaded before invoking the visitor because visitors commonly
/// reinsert the current index into a free/retired stack, and `push` overwrites
/// that index's intrusive `next` link.
///
/// This is not a linearizable snapshot of a live stack. Use it for detached
/// chains, quiesced save paths, or validation-style best-effort inspection.
pub fn walkDetached(first_index: u32, link_context: anytype, visitor: anytype) !void {
    var current = first_index;
    while (current != EMPTY_INDEX) {
        const next = try link_context.nextIndex(current);
        try visitor.visit(current);
        current = next;
    }
}

pub const LockFreeIndexStack = struct {
    head: *std.atomic.Value(u64),

    pub fn init(head: *std.atomic.Value(u64)) LockFreeIndexStack {
        return .{ .head = head };
    }

    pub fn headIndex(self: LockFreeIndexStack) u32 {
        return index_stack.headIndex(self.head.load(.acquire));
    }

    pub fn push(self: LockFreeIndexStack, entry: *types.ReclamationEntry, index: u32) void {
        std.debug.assert(index != EMPTY_INDEX);
        while (true) {
            const old_head = self.head.load(.acquire);
            entry.next.store(index_stack.headIndex(old_head), .release);
            const new_head = packHead(index, headTag(old_head) +% 1);
            if (self.head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return;
        }
    }

    pub fn pop(self: LockFreeIndexStack, entry_context: anytype) ?u32 {
        while (true) {
            const old_head = self.head.load(.acquire);
            const index = index_stack.headIndex(old_head);
            if (index == EMPTY_INDEX) return null;

            const entry = entry_context.entryAt(index);
            const next = entry.next.load(.acquire);
            const new_head = packHead(next, headTag(old_head) +% 1);
            if (self.head.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) == null) return index;
        }
    }

    /// Atomically removes every currently reachable index from the stack and
    /// returns the first index of that removed chain.
    ///
    /// This is a bulk pop, not destruction: the returned chain is now owned by
    /// the caller. Each index must later be reinserted, moved to another owner,
    /// or otherwise accounted for by the caller.
    pub fn detach(self: LockFreeIndexStack) u32 {
        const observed = self.head.load(.acquire);
        const detached = self.head.swap(packHead(EMPTY_INDEX, headTag(observed) +% 1), .acq_rel);
        return index_stack.headIndex(detached);
    }
};

const index_stack = @This();
