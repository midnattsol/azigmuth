const std = @import("std");
const types = @import("../../core/types.zig");

pub const NodeMeta = extern struct {
    published_meta: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(types.PublishedMeta{})),

    pub fn loadPublishedMeta(self: *const NodeMeta) types.PublishedMeta {
        return @bitCast(self.published_meta.load(.acquire));
    }

    pub fn storePublishedMeta(self: *NodeMeta, meta: types.PublishedMeta) void {
        self.published_meta.store(@bitCast(meta), .release);
    }

    pub fn cmpxchgPublishedMeta(self: *NodeMeta, expected: types.PublishedMeta, desired: types.PublishedMeta) ?types.PublishedMeta {
        const actual = self.published_meta.cmpxchgStrong(@bitCast(expected), @bitCast(desired), .acq_rel, .acquire);
        return if (actual) |raw| @as(types.PublishedMeta, @bitCast(raw)) else null;
    }
};

pub fn desiredMetaForPublishFwd(meta: types.PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.fwd_idx = 1 - meta.fwd_idx;
    desired.needs_repair_fwd = needs_repair_fwd;
    return desired.withFwdDegree(new_degree_fwd);
}

pub fn desiredMetaForPublishRev(meta: types.PublishedMeta, needs_repair_rev: bool, new_degree_rev: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.rev_idx = 1 - meta.rev_idx;
    desired.needs_repair_rev = needs_repair_rev;
    return desired.withRevDegree(new_degree_rev);
}

pub fn desiredMetaForPublishBoth(meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.fwd_idx = 1 - meta.fwd_idx;
    desired.rev_idx = 1 - meta.rev_idx;
    desired.needs_repair_fwd = flags.needs_repair_fwd;
    desired.needs_repair_rev = flags.needs_repair_rev;
    desired.removed = flags.removed;
    return desired.withFwdDegree(fwd_degree).withRevDegree(rev_degree);
}

pub fn desiredMetaForUpdateFwd(meta: types.PublishedMeta, needs_repair_fwd: bool, new_degree_fwd: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.needs_repair_fwd = needs_repair_fwd;
    return desired.withFwdDegree(new_degree_fwd);
}

pub fn desiredMetaForUpdateRev(meta: types.PublishedMeta, needs_repair_rev: bool, new_degree_rev: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.needs_repair_rev = needs_repair_rev;
    return desired.withRevDegree(new_degree_rev);
}

pub fn desiredMetaForUpdateBoth(meta: types.PublishedMeta, flags: types.NodeFlags, fwd_degree: u32, rev_degree: u32) types.PublishedMeta {
    var desired = meta.bumpedVersion();
    desired.needs_repair_fwd = flags.needs_repair_fwd;
    desired.needs_repair_rev = flags.needs_repair_rev;
    desired.removed = flags.removed;
    return desired.withFwdDegree(fwd_degree).withRevDegree(rev_degree);
}

comptime {
    if (@sizeOf(NodeMeta) != @sizeOf(std.atomic.Value(u64))) {
        @compileError("NodeMeta must contain only the published_meta word");
    }
}
