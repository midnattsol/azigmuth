const types = @import("../../core/types.zig");

pub const TINY_MODE_BIT: u32 = 0x8000_0000;

pub const NodePublished = extern struct {
    fwd: [2]types.SideAdj,
    rev: [2]types.SideAdj,
    fwd_degrees: [2]u32 = [_]u32{0} ** 2,
    rev_degrees: [2]u32 = [_]u32{0} ** 2,

    /// Whether the published side is globally sorted across its whole block
    /// sequence (freeze/repair/repack layouts). Double-buffered with the side
    /// so the bit always describes the published layout. False is always safe:
    /// lookups just take the linear per-block path.
    fwd_sorted: [2]u8 = [_]u8{0} ** 2,
    rev_sorted: [2]u8 = [_]u8{0} ** 2,

    pub fn isTiny(side: *const types.SideAdj) bool {
        return (side.block_count & TINY_MODE_BIT) != 0;
    }

    pub fn tinyCount(side: *const types.SideAdj) u16 {
        return @intCast(side.block_count & 0x7FFF_FFFF);
    }

    pub fn makeTiny(slot_idx: u32, count: u16) types.SideAdj {
        return .{
            .first_block = slot_idx,
            .block_count = TINY_MODE_BIT | count,
            .group_count = 0,
            .first_group = 0,
        };
    }

    pub fn publishedFwdFromMeta(self: *const NodePublished, meta: types.PublishedMeta) types.SideAdj {
        return self.fwd[meta.fwd_idx];
    }

    pub fn publishedRevFromMeta(self: *const NodePublished, meta: types.PublishedMeta) types.SideAdj {
        return self.rev[meta.rev_idx];
    }

    pub fn stagingFwd(self: *NodePublished, meta: types.PublishedMeta) *types.SideAdj {
        return &self.fwd[1 - meta.fwd_idx];
    }

    pub fn stagingRev(self: *NodePublished, meta: types.PublishedMeta) *types.SideAdj {
        return &self.rev[1 - meta.rev_idx];
    }

    pub fn publishedFwdDegreeFromMeta(self: *const NodePublished, meta: types.PublishedMeta) u32 {
        return if (meta.degree_fwd_overflow) self.fwd_degrees[meta.fwd_idx] else meta.degree_fwd;
    }

    pub fn publishedRevDegreeFromMeta(self: *const NodePublished, meta: types.PublishedMeta) u32 {
        return if (meta.degree_rev_overflow) self.rev_degrees[meta.rev_idx] else meta.degree_rev;
    }

    pub fn stagingFwdDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.fwd_degrees[1 - meta.fwd_idx];
    }

    pub fn stagingRevDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.rev_degrees[1 - meta.rev_idx];
    }

    pub fn publishedFwdDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.fwd_degrees[meta.fwd_idx];
    }

    pub fn publishedRevDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.rev_degrees[meta.rev_idx];
    }

    pub fn copyPublishedToStagingFwd(self: *NodePublished, meta: types.PublishedMeta) void {
        self.fwd[1 - meta.fwd_idx] = self.fwd[meta.fwd_idx];
    }

    pub fn copyPublishedToStagingRev(self: *NodePublished, meta: types.PublishedMeta) void {
        self.rev[1 - meta.rev_idx] = self.rev[meta.rev_idx];
    }

    pub fn publishedFwdSortedFromMeta(self: *const NodePublished, meta: types.PublishedMeta) bool {
        return self.fwd_sorted[meta.fwd_idx] != 0;
    }

    pub fn publishedRevSortedFromMeta(self: *const NodePublished, meta: types.PublishedMeta) bool {
        return self.rev_sorted[meta.rev_idx] != 0;
    }

    pub fn stagingFwdSorted(self: *NodePublished, meta: types.PublishedMeta) *u8 {
        return &self.fwd_sorted[1 - meta.fwd_idx];
    }

    pub fn stagingRevSorted(self: *NodePublished, meta: types.PublishedMeta) *u8 {
        return &self.rev_sorted[1 - meta.rev_idx];
    }
};

comptime {
    if (@sizeOf(NodePublished) != (@sizeOf([2]types.SideAdj) * 2) + (@sizeOf([2]u32) * 2) + (@sizeOf([2]u8) * 2)) {
        @compileError("NodePublished must cover the side buffers plus degree and sorted sidecars");
    }
}
