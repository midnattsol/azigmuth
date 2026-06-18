const common = @import("common.zig");
const constants = @import("../../core/constants.zig");
const types = @import("../../core/types.zig");

pub fn validateRemovedNodeState(adjacency: types.NodeAdj, degree_fwd: u64, degree_rev: u64) !void {
    if (adjacency.block_count_fwd != 0 or adjacency.segment_count_fwd != 0 or degree_fwd != 0) {
        return error.CorruptGraph;
    }
    if (degree_rev != 0) {
        return error.CorruptGraph;
    }
    // removeNode clears both adjacency descriptors synchronously:
    // a removed node with structural reverse storage is corruption even when
    // its published degree is already zero.
    if (adjacency.block_count_rev != 0 or adjacency.segment_count_rev != 0) {
        return error.CorruptGraph;
    }
    if (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev) {
        return error.CorruptGraph;
    }
}

pub fn validateLiveNodeState(
    adjacency: types.NodeAdj,
    degree_fwd: u64,
    degree_rev: u64,
    visible_fwd: u64,
    visible_rev: u64,
    has_forward_tombstone: bool,
    has_reverse_tombstone: bool,
    check_segment_limits: bool,
) !void {
    if (adjacency.flags.removed) {
        return validateRemovedNodeState(adjacency, degree_fwd, degree_rev);
    }

    if (degree_fwd != visible_fwd) {
        return error.CorruptGraph;
    }
    if (degree_rev != visible_rev) {
        return error.CorruptGraph;
    }
    if (!adjacency.flags.needs_repair_fwd and has_forward_tombstone) {
        return error.CorruptGraph;
    }
    if (!adjacency.flags.needs_repair_rev and has_reverse_tombstone) {
        return error.CorruptGraph;
    }
    if (check_segment_limits) {
        if (adjacency.segment_count_fwd > constants.MAX_SEGMENTS_PER_NODE and !adjacency.flags.needs_repair_fwd) {
            return error.CorruptGraph;
        }
        if (adjacency.segment_count_rev > constants.MAX_SEGMENTS_PER_NODE and !adjacency.flags.needs_repair_rev) {
            return error.CorruptGraph;
        }
    }
}

pub fn validateVisibleTotals(total_visible_forward: u64, total_visible_reverse: u64) !void {
    if (total_visible_forward != total_visible_reverse) {
        return error.CorruptGraph;
    }
}
