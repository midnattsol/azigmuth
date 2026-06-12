//! Lazy two-level radix directory for atomically-published page pointers.
//!
//! Layout: the first `INLINE` pages live in slots embedded in the directory
//! itself (zero heap cost for small graphs); every further page resolves
//! through a lazily allocated root array of leaf pointers, each leaf covering
//! `L2` pages. Both levels are published once via CAS and never move, so
//! lock-free readers only ever observe absent (0) or fully initialized
//! pointers. Fixed inline footprint is `INLINE × @sizeOf(usize)` plus one
//! root pointer — capacity ceilings are paid only when actually used.

const std = @import("std");

pub fn RadixDirectory(comptime INLINE: usize, comptime L1: usize, comptime L2: usize) type {
    return struct {
        const Self = @This();

        inline_slots: [INLINE]std.atomic.Value(usize) =
            [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** INLINE,
        /// 0 while unallocated; otherwise `@intFromPtr` of a `[L1]` array of
        /// leaf pointers (each 0 or `@intFromPtr` of a `[L2]` slot array).
        root: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub const inline_count: usize = INLINE;
        pub const l1_count: usize = L1;
        pub const l2_count: usize = L2;
        pub const max_pages: usize = INLINE + L1 * L2;
        /// Iteration domain for `leafSliceAtConst`: index 0 is the inline
        /// slot block, indices 1..=L1 are the lazily allocated leaves.
        pub const leaf_count: usize = 1 + L1;

        fn sliceFromRaw(raw: usize) []std.atomic.Value(usize) {
            const ptr: [*]std.atomic.Value(usize) = @ptrFromInt(raw);
            return ptr[0..L2];
        }

        fn sliceFromRawConst(raw: usize) []const std.atomic.Value(usize) {
            const ptr: [*]const std.atomic.Value(usize) = @ptrFromInt(raw);
            return ptr[0..L2];
        }

        fn rootFromRaw(raw: usize) []std.atomic.Value(usize) {
            const ptr: [*]std.atomic.Value(usize) = @ptrFromInt(raw);
            return ptr[0..L1];
        }

        fn rootFromRawConst(raw: usize) []const std.atomic.Value(usize) {
            const ptr: [*]const std.atomic.Value(usize) = @ptrFromInt(raw);
            return ptr[0..L1];
        }

        fn allocLevel(allocator: std.mem.Allocator, comptime len: usize) ![]std.atomic.Value(usize) {
            const level = try allocator.alloc(std.atomic.Value(usize), len);
            for (level) |*slot| slot.* = std.atomic.Value(usize).init(0);
            return level;
        }

        /// Publish-once helper: install `candidate` into `slot` unless another
        /// thread already published a level there, in which case the candidate
        /// is freed and the published level wins.
        fn publishLevel(
            allocator: std.mem.Allocator,
            slot: *std.atomic.Value(usize),
            candidate: []std.atomic.Value(usize),
        ) usize {
            const candidate_raw = @intFromPtr(candidate.ptr);
            if (slot.cmpxchgStrong(0, candidate_raw, .acq_rel, .acquire)) |published_raw| {
                allocator.free(candidate);
                return published_raw;
            }
            return candidate_raw;
        }

        fn ensureRoot(self: *Self, allocator: std.mem.Allocator) ![]std.atomic.Value(usize) {
            const existing = self.root.load(.acquire);
            if (existing != 0) return rootFromRaw(existing);
            const candidate = try allocLevel(allocator, L1);
            return rootFromRaw(publishLevel(allocator, &self.root, candidate));
        }

        fn ensureLeaf(allocator: std.mem.Allocator, leaf_slot: *std.atomic.Value(usize)) ![]std.atomic.Value(usize) {
            const existing = leaf_slot.load(.acquire);
            if (existing != 0) return sliceFromRaw(existing);
            const candidate = try allocLevel(allocator, L2);
            return sliceFromRaw(publishLevel(allocator, leaf_slot, candidate));
        }

        pub fn maxPages(self: *const Self) usize {
            _ = self;
            return max_pages;
        }

        pub fn load(self: *const Self, page_idx: u32) usize {
            const flat_idx: usize = @intCast(page_idx);
            if (flat_idx < INLINE) return self.inline_slots[flat_idx].load(.acquire);
            const tree_idx = flat_idx - INLINE;
            if (tree_idx >= L1 * L2) return 0;

            const root_raw = self.root.load(.acquire);
            if (root_raw == 0) return 0;
            const leaf_raw = rootFromRawConst(root_raw)[tree_idx / L2].load(.acquire);
            if (leaf_raw == 0) return 0;
            return sliceFromRawConst(leaf_raw)[tree_idx % L2].load(.acquire);
        }

        pub fn slotPtr(self: *Self, allocator: std.mem.Allocator, page_idx: u32) !*std.atomic.Value(usize) {
            const flat_idx: usize = @intCast(page_idx);
            if (flat_idx < INLINE) return &self.inline_slots[flat_idx];
            const tree_idx = flat_idx - INLINE;
            if (tree_idx >= L1 * L2) return error.OutOfMemory;

            const root_slice = try self.ensureRoot(allocator);
            const leaf = try ensureLeaf(allocator, &root_slice[tree_idx / L2]);
            return &leaf[tree_idx % L2];
        }

        /// Returns one block of page slots for teardown/diagnostic iteration:
        /// index 0 is the inline block, indices 1..=L1 the allocated leaves
        /// (null when absent). Slices differ in length (INLINE vs L2).
        pub fn leafSliceAtConst(self: *const Self, leaf_idx: usize) ?[]const std.atomic.Value(usize) {
            if (leaf_idx == 0) return self.inline_slots[0..];
            if (leaf_idx > L1) return null;

            const root_raw = self.root.load(.acquire);
            if (root_raw == 0) return null;
            const leaf_raw = rootFromRawConst(root_raw)[leaf_idx - 1].load(.acquire);
            if (leaf_raw == 0) return null;
            return sliceFromRawConst(leaf_raw);
        }

        pub fn deinitLeaves(self: *Self, allocator: std.mem.Allocator) void {
            const root_raw = self.root.load(.acquire);
            if (root_raw == 0) return;
            const root_slice = rootFromRaw(root_raw);
            for (root_slice) |*leaf_slot| {
                const leaf_raw = leaf_slot.load(.acquire);
                if (leaf_raw == 0) continue;
                allocator.free(sliceFromRaw(leaf_raw));
                leaf_slot.store(0, .release);
            }
            allocator.free(root_slice);
            self.root.store(0, .release);
        }
    };
}
