const std = @import("std");

pub const BlockIter = struct {
    block_idx: u32,
    live: u7,
    pos: u7,
    current_key: u32,
    current_id: u32 = 0,
};

fn blockIterLess(lhs: BlockIter, rhs: BlockIter) bool {
    if (lhs.current_key != rhs.current_key) return lhs.current_key < rhs.current_key;
    return lhs.current_id < rhs.current_id;
}

fn siftUp(heap: []BlockIter, start_idx: usize) void {
    var child_idx = start_idx;
    while (child_idx > 0) {
        const parent_idx = (child_idx - 1) / 2;
        if (!blockIterLess(heap[child_idx], heap[parent_idx])) break;
        std.mem.swap(BlockIter, &heap[parent_idx], &heap[child_idx]);
        child_idx = parent_idx;
    }
}

fn siftDown(heap: []BlockIter, start_idx: usize) void {
    var parent_idx = start_idx;
    while (true) {
        const left_idx = parent_idx * 2 + 1;
        if (left_idx >= heap.len) break;

        const right_idx = left_idx + 1;
        var min_idx = left_idx;
        if (right_idx < heap.len and blockIterLess(heap[right_idx], heap[left_idx])) {
            min_idx = right_idx;
        }
        if (!blockIterLess(heap[min_idx], heap[parent_idx])) break;

        std.mem.swap(BlockIter, &heap[parent_idx], &heap[min_idx]);
        parent_idx = min_idx;
    }
}

pub fn heapPush(heap: *std.ArrayList(BlockIter), item: BlockIter) void {
    heap.appendAssumeCapacity(item);
    siftUp(heap.items, heap.items.len - 1);
}

pub fn heapRemoveTop(heap: *std.ArrayList(BlockIter)) void {
    _ = heap.swapRemove(0);
    if (heap.items.len > 0) siftDown(heap.items, 0);
}

pub fn heapUpdateTop(heap: *std.ArrayList(BlockIter), item: BlockIter) void {
    heap.items[0] = item;
    siftDown(heap.items, 0);
}
