const std = @import("std");
const types = @import("../../core/types.zig");

pub const NodePublicationCell = extern struct {
    state: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(types.NodePublicationState{})),

    pub fn loadPublicationState(self: *const NodePublicationCell) types.NodePublicationState {
        return @bitCast(self.state.load(.acquire));
    }

    pub fn storePublicationState(self: *NodePublicationCell, state: types.NodePublicationState) void {
        self.state.store(@bitCast(state), .release);
    }

    pub fn cmpxchgPublicationState(self: *NodePublicationCell, expected: types.NodePublicationState, desired: types.NodePublicationState) ?types.NodePublicationState {
        const actual = self.state.cmpxchgStrong(@bitCast(expected), @bitCast(desired), .acq_rel, .acquire);
        return if (actual) |raw| @as(types.NodePublicationState, @bitCast(raw)) else null;
    }
};

pub fn desiredStateForPublishFwd(state: types.NodePublicationState, needs_repair_fwd: bool, new_degree_fwd: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.idx_fwd = 1 - state.idx_fwd;
    desired.needs_repair_fwd = needs_repair_fwd;
    return desired.withFwdDegree(new_degree_fwd);
}

pub fn desiredStateForPublishRev(state: types.NodePublicationState, needs_repair_rev: bool, new_degree_rev: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.idx_rev = 1 - state.idx_rev;
    desired.needs_repair_rev = needs_repair_rev;
    return desired.withRevDegree(new_degree_rev);
}

pub fn desiredStateForPublishBoth(state: types.NodePublicationState, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.idx_fwd = 1 - state.idx_fwd;
    desired.idx_rev = 1 - state.idx_rev;
    desired.needs_repair_fwd = flags.needs_repair_fwd;
    desired.needs_repair_rev = flags.needs_repair_rev;
    desired.removed = flags.removed;
    return desired.withFwdDegree(fwd_degree).withRevDegree(rev_degree);
}

pub fn desiredStateForUpdateFwd(state: types.NodePublicationState, needs_repair_fwd: bool, new_degree_fwd: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.needs_repair_fwd = needs_repair_fwd;
    return desired.withFwdDegree(new_degree_fwd);
}

pub fn desiredStateForUpdateRev(state: types.NodePublicationState, needs_repair_rev: bool, new_degree_rev: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.needs_repair_rev = needs_repair_rev;
    return desired.withRevDegree(new_degree_rev);
}

pub fn desiredStateForUpdateBoth(state: types.NodePublicationState, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32) types.NodePublicationState {
    var desired = state.bumpedVersion();
    desired.needs_repair_fwd = flags.needs_repair_fwd;
    desired.needs_repair_rev = flags.needs_repair_rev;
    desired.removed = flags.removed;
    return desired.withFwdDegree(fwd_degree).withRevDegree(rev_degree);
}

comptime {
    if (@sizeOf(NodePublicationCell) != @sizeOf(std.atomic.Value(u64))) {
        @compileError("NodePublicationCell must contain only the publication state word");
    }
}
