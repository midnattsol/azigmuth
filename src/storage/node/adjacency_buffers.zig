const types = @import("../../core/types.zig");

pub const TINY_MODE_BIT: u32 = 0x8000_0000;

pub const NodeAdjacencyBuffers = extern struct {
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
            .segment_count = 0,
            .first_segment = 0,
        };
    }

    pub fn publishedFwdFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) types.SideAdj {
        return self.fwd[state.idx_fwd];
    }

    pub fn publishedRevFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) types.SideAdj {
        return self.rev[state.idx_rev];
    }

    pub fn stagingFwd(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *types.SideAdj {
        return &self.fwd[1 - state.idx_fwd];
    }

    pub fn stagingRev(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *types.SideAdj {
        return &self.rev[1 - state.idx_rev];
    }

    pub fn publishedFwdDegreeFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) u32 {
        return if (state.degree_fwd_overflow) self.degrees_fwd[state.idx_fwd] else state.degree_fwd;
    }

    pub fn publishedRevDegreeFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) u32 {
        return if (state.degree_rev_overflow) self.degrees_rev[state.idx_rev] else state.degree_rev;
    }

    pub fn stagingFwdDegree(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u32 {
        return &self.degrees_fwd[1 - state.idx_fwd];
    }

    pub fn stagingRevDegree(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u32 {
        return &self.degrees_rev[1 - state.idx_rev];
    }

    pub fn publishedFwdDegree(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u32 {
        return &self.degrees_fwd[state.idx_fwd];
    }

    pub fn publishedRevDegree(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u32 {
        return &self.degrees_rev[state.idx_rev];
    }

    pub fn copyPublishedToStagingFwd(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) void {
        self.fwd[1 - state.idx_fwd] = self.fwd[state.idx_fwd];
    }

    pub fn copyPublishedToStagingRev(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) void {
        self.rev[1 - state.idx_rev] = self.rev[state.idx_rev];
    }

    pub fn publishedFwdSortedFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) bool {
        return self.sorted_fwd[state.idx_fwd] != 0;
    }

    pub fn publishedRevSortedFromState(self: *const NodeAdjacencyBuffers, state: types.NodePublicationState) bool {
        return self.sorted_rev[state.idx_rev] != 0;
    }

    pub fn stagingFwdSorted(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u8 {
        return &self.sorted_fwd[1 - state.idx_fwd];
    }

    pub fn stagingRevSorted(self: *NodeAdjacencyBuffers, state: types.NodePublicationState) *u8 {
        return &self.sorted_rev[1 - state.idx_rev];
    }
};

comptime {
    if (@sizeOf(NodeAdjacencyBuffers) != (@sizeOf([2]types.SideAdj) * 2) + (@sizeOf([2]u32) * 2) + (@sizeOf([2]u8) * 2)) {
        @compileError("NodeAdjacencyBuffers must cover the side buffers plus degree and sorted sidecars");
    }
}
