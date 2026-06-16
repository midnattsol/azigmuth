const types = @import("../../core/types.zig");

pub const TINY_MODE_BIT: u32 = 0x8000_0000;

pub const NodePublished = extern struct {
    fwd: [2]types.SideAdj,
    rev: [2]types.SideAdj,
    degrees_fwd: [2]u32 = [_]u32{0} ** 2,
    degrees_rev: [2]u32 = [_]u32{0} ** 2,

    /// Whether the published side is globally sorted across its whole block
    /// sequence (freeze/repair/repack layouts). Double-buffered with the side
    /// so the bit always describes the published layout. False is always safe:
    /// lookups just take the linear per-block path.
    sorted_fwd: [2]u8 = [_]u8{0} ** 2,
    sorted_rev: [2]u8 = [_]u8{0} ** 2,

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
        return self.fwd[meta.idx_fwd];
    }

    pub fn publishedRevFromMeta(self: *const NodePublished, meta: types.PublishedMeta) types.SideAdj {
        return self.rev[meta.idx_rev];
    }

    pub fn stagingFwd(self: *NodePublished, meta: types.PublishedMeta) *types.SideAdj {
        return &self.fwd[1 - meta.idx_fwd];
    }

    pub fn stagingRev(self: *NodePublished, meta: types.PublishedMeta) *types.SideAdj {
        return &self.rev[1 - meta.idx_rev];
    }

    pub fn publishedFwdDegreeFromMeta(self: *const NodePublished, meta: types.PublishedMeta) u32 {
        return if (meta.degree_fwd_overflow) self.degrees_fwd[meta.idx_fwd] else meta.degree_fwd;
    }

    pub fn publishedRevDegreeFromMeta(self: *const NodePublished, meta: types.PublishedMeta) u32 {
        return if (meta.degree_rev_overflow) self.degrees_rev[meta.idx_rev] else meta.degree_rev;
    }

    pub fn stagingFwdDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.degrees_fwd[1 - meta.idx_fwd];
    }

    pub fn stagingRevDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.degrees_rev[1 - meta.idx_rev];
    }

    pub fn publishedFwdDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.degrees_fwd[meta.idx_fwd];
    }

    pub fn publishedRevDegree(self: *NodePublished, meta: types.PublishedMeta) *u32 {
        return &self.degrees_rev[meta.idx_rev];
    }

    pub fn copyPublishedToStagingFwd(self: *NodePublished, meta: types.PublishedMeta) void {
        self.fwd[1 - meta.idx_fwd] = self.fwd[meta.idx_fwd];
    }

    pub fn copyPublishedToStagingRev(self: *NodePublished, meta: types.PublishedMeta) void {
        self.rev[1 - meta.idx_rev] = self.rev[meta.idx_rev];
    }

    pub fn publishedFwdSortedFromMeta(self: *const NodePublished, meta: types.PublishedMeta) bool {
        return self.sorted_fwd[meta.idx_fwd] != 0;
    }

    pub fn publishedRevSortedFromMeta(self: *const NodePublished, meta: types.PublishedMeta) bool {
        return self.sorted_rev[meta.idx_rev] != 0;
    }

    pub fn stagingFwdSorted(self: *NodePublished, meta: types.PublishedMeta) *u8 {
        return &self.sorted_fwd[1 - meta.idx_fwd];
    }

    pub fn stagingRevSorted(self: *NodePublished, meta: types.PublishedMeta) *u8 {
        return &self.sorted_rev[1 - meta.idx_rev];
    }
};

comptime {
    if (@sizeOf(NodePublished) != (@sizeOf([2]types.SideAdj) * 2) + (@sizeOf([2]u32) * 2) + (@sizeOf([2]u8) * 2)) {
        @compileError("NodePublished must cover the side buffers plus degree and sorted sidecars");
    }
}
