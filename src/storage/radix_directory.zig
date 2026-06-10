const std = @import("std");

pub fn RadixDirectory(comptime L1: usize, comptime L2: usize) type {
    return struct {
        const Self = @This();

        first_leaf: [L2]std.atomic.Value(usize) =
            [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** L2,
        root: [L1]std.atomic.Value(usize) =
            [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** L1,

        pub const l1_count: usize = L1;
        pub const l2_count: usize = L2;
        pub const max_pages: usize = L1 * L2;

        fn leafFromRaw(raw: usize) []std.atomic.Value(usize) {
            const leaf_ptr: [*]std.atomic.Value(usize) = @ptrFromInt(raw);
            return leaf_ptr[0..L2];
        }

        fn leafFromRawConst(raw: usize) []const std.atomic.Value(usize) {
            const leaf_ptr: [*]const std.atomic.Value(usize) = @ptrFromInt(raw);
            return leaf_ptr[0..L2];
        }

        fn split(page_index: u32) struct { leaf_idx: usize, slot_idx: usize } {
            const flat_idx: usize = @intCast(page_index);
            return .{
                .leaf_idx = flat_idx / L2,
                .slot_idx = flat_idx % L2,
            };
        }

        fn ensureLeaf(self: *Self, allocator: std.mem.Allocator, leaf_idx: usize) ![]std.atomic.Value(usize) {
            if (leaf_idx == 0) return self.first_leaf[0..];

            const existing = self.root[leaf_idx].load(.acquire);
            if (existing != 0) return leafFromRaw(existing);

            const new_leaf = try allocator.alloc(std.atomic.Value(usize), L2);
            errdefer allocator.free(new_leaf);
            for (new_leaf) |*slot| slot.* = std.atomic.Value(usize).init(0);

            const new_raw = @intFromPtr(new_leaf.ptr);
            if (self.root[leaf_idx].cmpxchgStrong(0, new_raw, .acq_rel, .acquire)) |published_raw| {
                allocator.free(new_leaf);
                return leafFromRaw(published_raw);
            }

            return new_leaf;
        }

        pub fn maxPages(self: *const Self) usize {
            _ = self;
            return max_pages;
        }

        pub fn load(self: *const Self, page_index: u32) usize {
            const flat_idx: usize = @intCast(page_index);
            if (flat_idx >= max_pages) return 0;

            const indices = split(page_index);
            if (indices.leaf_idx == 0) return self.first_leaf[indices.slot_idx].load(.acquire);

            const leaf_raw = self.root[indices.leaf_idx].load(.acquire);
            if (leaf_raw == 0) return 0;

            return leafFromRawConst(leaf_raw)[indices.slot_idx].load(.acquire);
        }

        pub fn slotPtr(self: *Self, allocator: std.mem.Allocator, page_index: u32) !*std.atomic.Value(usize) {
            const flat_idx: usize = @intCast(page_index);
            if (flat_idx >= max_pages) return error.OutOfMemory;

            const indices = split(page_index);
            const leaf = try ensureLeaf(self, allocator, indices.leaf_idx);
            return &leaf[indices.slot_idx];
        }

        pub fn leafSliceAtConst(self: *const Self, leaf_idx: usize) ?[]const std.atomic.Value(usize) {
            if (leaf_idx >= L1) return null;
            if (leaf_idx == 0) return self.first_leaf[0..];

            const raw = self.root[leaf_idx].load(.acquire);
            if (raw == 0) return null;
            return leafFromRawConst(raw);
        }

        pub fn deinitLeaves(self: *Self, allocator: std.mem.Allocator) void {
            var leaf_idx: usize = 1;
            while (leaf_idx < L1) : (leaf_idx += 1) {
                const raw = self.root[leaf_idx].load(.acquire);
                if (raw == 0) continue;
                allocator.free(leafFromRaw(raw));
                self.root[leaf_idx].store(0, .release);
            }
        }
    };
}
