//! RCU-style reader/writer synchronization and block retirement.

const graph = @import("graph_core.zig");

pub fn readerEnter(core: *graph.GraphCore) u64 {
    _ = core.active_readers.fetchAdd(1, .monotonic);
    return core.epoch.load(.acquire);
}

pub fn readerExit(core: *graph.GraphCore) void {
    _ = core.active_readers.fetchSub(1, .monotonic);
}

pub fn retireBlockFwd(core: *graph.GraphCore, block_idx: u32) !void {
    const current_epoch = core.epoch.load(.acquire);
    try core.retired_blocks_fwd.append(core.allocator, .{ .block = block_idx, .epoch = current_epoch });
}

pub fn retireBlockRev(core: *graph.GraphCore, block_idx: u32) !void {
    const current_epoch = core.epoch.load(.acquire);
    try core.retired_blocks_rev.append(core.allocator, .{ .block = block_idx, .epoch = current_epoch });
}

pub fn bumpEpoch(core: *graph.GraphCore) void {
    _ = core.epoch.fetchAdd(1, .monotonic);
}

pub fn reclaimRetired(core: *graph.GraphCore) void {
    if (core.active_readers.load(.acquire) > 0) return;
    const safe_epoch = core.epoch.load(.acquire) -| 2;

    while (core.retired_blocks_fwd.items.len > 0) {
        if (core.retired_blocks_fwd.items[0].epoch > safe_epoch) break;
        core.free_blocks_fwd.append(core.allocator, core.retired_blocks_fwd.orderedRemove(0).block) catch {};
    }
    while (core.retired_blocks_rev.items.len > 0) {
        if (core.retired_blocks_rev.items[0].epoch > safe_epoch) break;
        core.free_blocks_rev.append(core.allocator, core.retired_blocks_rev.orderedRemove(0).block) catch {};
    }
}
