const tiny_config = @import("../../core/tiny_config.zig");
const types = @import("../../core/types.zig");

pub const TinyFwdEntry = extern struct {
    destination: u32 = 0,
    relation: u16 = 0,
    flags: types.EdgeFlags = @bitCast(@as(u16, 0)),
    edge_id: u32 = 0,
};

pub const TinyFwdSlot = extern struct {
    entries: [tiny_config.TINY_FWD_CAP_SIMPLE]TinyFwdEntry = [_]TinyFwdEntry{.{}} ** tiny_config.TINY_FWD_CAP_SIMPLE,
};

pub const TinyRevSlot = extern struct {
    sources: [tiny_config.TINY_REV_CAP]u32 = [_]u32{0} ** tiny_config.TINY_REV_CAP,
};

pub const TINY_FWD_SLOTS_PER_PAGE: u32 = 256;
pub const TINY_REV_SLOTS_PER_PAGE: u32 = 256;

pub fn fwdCap(multigraph_enabled: bool) u16 {
    return if (multigraph_enabled) tiny_config.TINY_FWD_CAP_MULTI else tiny_config.TINY_FWD_CAP_SIMPLE;
}

pub fn insertFwd(slot: *TinyFwdSlot, count: u16, destination: u32, relation: u16, flags: types.EdgeFlags, edge_id: u32, multigraph_enabled: bool) !u16 {
    var insertion_idx: u16 = 0;
    while (insertion_idx < count) : (insertion_idx += 1) {
        const current = slot.entries[insertion_idx];
        if (current.destination < destination) continue;
        if (current.destination == destination) {
            if (!multigraph_enabled) return error.EdgeAlreadyExists;
            if (current.edge_id < edge_id) continue;
        }
        break;
    }
    var shift = count;
    while (shift > insertion_idx) : (shift -= 1) {
        slot.entries[shift] = slot.entries[shift - 1];
    }
    slot.entries[insertion_idx] = .{
        .destination = destination,
        .relation = relation,
        .flags = flags,
        .edge_id = edge_id,
    };
    return count + 1;
}

pub fn insertRev(slot: *TinyRevSlot, count: u16, source: u32) u16 {
    var insertion_idx: u16 = 0;
    while (insertion_idx < count and slot.sources[insertion_idx] < source) : (insertion_idx += 1) {}
    var shift = count;
    while (shift > insertion_idx) : (shift -= 1) {
        slot.sources[shift] = slot.sources[shift - 1];
    }
    slot.sources[insertion_idx] = source;
    return count + 1;
}

pub fn removeFwd(slot: *TinyFwdSlot, count: u16, destination: u32, edge_id: ?u32, multigraph_enabled: bool) ?u16 {
    var match_idx: ?u16 = null;
    for (0..count) |entry_idx| {
        const entry = slot.entries[entry_idx];
        if (entry.destination != destination) continue;
        if (multigraph_enabled and edge_id != null and entry.edge_id != edge_id.?) continue;
        match_idx = @intCast(entry_idx);
        break;
    }
    const removal_idx = match_idx orelse return null;
    var idx = removal_idx;
    while (idx + 1 < count) : (idx += 1) {
        slot.entries[idx] = slot.entries[idx + 1];
    }
    slot.entries[count - 1] = .{};
    return count - 1;
}

pub fn removeRev(slot: *TinyRevSlot, count: u16, source: u32) ?u16 {
    var match_idx: ?u16 = null;
    for (0..count) |entry_idx| {
        if (slot.sources[entry_idx] != source) continue;
        match_idx = @intCast(entry_idx);
        break;
    }
    const removal_idx = match_idx orelse return null;
    var idx = removal_idx;
    while (idx + 1 < count) : (idx += 1) {
        slot.sources[idx] = slot.sources[idx + 1];
    }
    slot.sources[count - 1] = 0;
    return count - 1;
}
