//! Snapshot loader by copy (SKELETON: every body is a TODO).
//!
//! Reads a snapshot file and reconstructs a fully mutable live graph in the
//! heap. The validation ladder (header → table → length → checksums) lives
//! in `io.zig` and is shared with `frozen.zig` — this module adds the
//! materialization: restore pages, replay NodeRecords, push free lists,
//! restore counters. Epochs/readers/repair queues start fresh
//! (reconstructed, never persisted).
//!
//! Index sanity beyond checksums (a checksum proves integrity, not honesty:
//! a well-checksummed file can still claim block_count > the section can
//! hold, or a free index past the frontier) is cross-checked during
//! restore — every index read from the payload is bounds-checked against
//! the header counters before use.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const graph = @import("../../graph.zig");
const frozen = @import("frozen.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const page_ops = @import("../page_ops.zig");
const node_tiny = @import("../node/tiny.zig");
const node_adjacency_buffers = @import("../node/adjacency_buffers.zig");
const format = @import("format.zig");
const validation = @import("validation.zig");

// TODO: narrow (validation.ValidateError || error{CorruptIndex, OutOfMemory}).
pub const LoadError = anyerror;

/// Loads `<sub_path>` into a fresh, fully mutable graph. GraphOptions are
/// not a parameter: multigraph / edge_properties come from the header flags.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: frozen.OpenOptions,
) LoadError!graph.Graph {
    var frozen_graph = try frozen.FrozenGraph.open(
        io,
        dir,
        sub_path,
        options,
    );
    errdefer frozen_graph.close();
    const graph_options = types.GraphOptions{
        .multigraph = frozen_graph.header.flags.multigraph,
        .edge_properties = frozen_graph.header.flags.edge_properties,
    };
    var mut_graph = try graph.Graph.initWithOptions(allocator, graph_options);
    errdefer mut_graph.deinit();

    // Restore page sections in order.
    const fwd_block_bytes = frozen_graph.sectionBytes(.blocks_fwd);
    try restoreEdgeBlocks(&mut_graph.graph, fwd_block_bytes, .fwd);
    const rev_block_bytes = frozen_graph.sectionBytes(.blocks_rev);
    try restoreEdgeBlocks(&mut_graph.graph, rev_block_bytes, .rev);

    try restoreBlockAliveCounts(&mut_graph.graph, frozen_graph.sectionBytes(.alive_fwd), .fwd);
    try restoreBlockAliveCounts(&mut_graph.graph, frozen_graph.sectionBytes(.alive_rev), .rev);

    if (graph_options.multigraph) {
        try restoreEdgeBlockIds(&mut_graph.graph, frozen_graph.sectionBytes(.edge_ids_fwd));
    }
    if (graph_options.edge_properties) {
        try restoreEdgeBlockPropRows(&mut_graph.graph, frozen_graph.sectionBytes(.prop_rows_fwd));
    }

    try restoreEdgeBlockSegments(&mut_graph.graph, frozen_graph.sectionBytes(.segments));
    try restoreTinySlots(&mut_graph.graph, frozen_graph.sectionBytes(.tiny_fwd), .fwd);
    try restoreTinySlots(&mut_graph.graph, frozen_graph.sectionBytes(.tiny_rev), .rev);

    // Restore node records.
    const node_records = frozen_graph.nodeRecords();
    const header = frozen_graph.header;
    for (0..@as(u32, @intCast(header.node_count))) |node_idx| {
        try restoreNodeRecord(&mut_graph.graph, @intCast(node_idx), node_records[node_idx], header);
    }

    // Restore free lists.
    try restoreFreeList(&mut_graph.graph, .free_blocks_fwd, frozen_graph.sectionBytes(.free_blocks_fwd), header);
    try restoreFreeList(&mut_graph.graph, .free_blocks_rev, frozen_graph.sectionBytes(.free_blocks_rev), header);
    try restoreFreeList(&mut_graph.graph, .free_tiny_fwd, frozen_graph.sectionBytes(.free_tiny_fwd), header);
    try restoreFreeList(&mut_graph.graph, .free_tiny_rev, frozen_graph.sectionBytes(.free_tiny_rev), header);
    try restoreFreeList(&mut_graph.graph, .free_segment_slots, frozen_graph.sectionBytes(.free_segment_slots), header);
    if (graph_options.edge_properties) {
        try restoreFreeList(&mut_graph.graph, .free_prop_rows, frozen_graph.sectionBytes(.free_prop_rows), header);
    }

    // Restore global counters from header.
    mut_graph.graph.block_fwd_count = header.block_fwd_count;
    mut_graph.graph.block_rev_count = header.block_rev_count;
    mut_graph.graph.segment_count = header.segment_count;
    mut_graph.graph.tiny_fwd_slot_count = header.tiny_fwd_slot_count;
    mut_graph.graph.tiny_rev_slot_count = header.tiny_rev_slot_count;

    mut_graph.graph.edge_count.store(header.edge_count, .release);
    mut_graph.graph.prop_row_count = header.prop_row_count;
    // node_count is set atomically by the node-record loop above via ensureNodePublicationPage;
    // publish it here.
    mut_graph.graph.node_count.store(@intCast(header.node_count), .release);

    frozen_graph.close();
    return mut_graph;
}

// ── Restore helpers (checksums already verified; indices still hostile) ──

/// Copies a raw page section back into freshly ensured engine pages.
/// `ensure*Capacity` + page-by-page @memcpy; the section family decides
/// which directory and page shape.
pub fn restoreEdgeBlocks(
    core: *graph_core.GraphCore,
    payload: []const u8,
    comptime side: adjacency.AdjSide,
) LoadError!void {
    const block_size = switch (side) {
        .fwd => @sizeOf(types.EdgeBlockFwd),
        .rev => @sizeOf(types.EdgeBlockRev),
    };
    const total_blocks = payload.len / block_size;

    try page_ops.ensureBlockCapacity(core, @intCast(total_blocks), side);
    const total_pages = (total_blocks + constants.EDGE_BLOCKS_PER_PAGE - 1) / constants.EDGE_BLOCKS_PER_PAGE;

    for (0..total_pages) |page_idx| {
        const start = page_idx * constants.EDGE_BLOCKS_PER_PAGE * block_size;
        const end = start + (constants.EDGE_BLOCKS_PER_PAGE * block_size);
        const source_copy = payload[start..@min(end, payload.len)];
        const page_destination: [*]u8 = @ptrFromInt(page_ops.edgeBlockPageRaw(
            core,
            @intCast(page_idx),
            side,
        ));
        @memcpy(page_destination, source_copy);
    }
}

pub fn restoreBlockAliveCounts(core: *graph_core.GraphCore, payload: []const u8, comptime side: adjacency.AdjSide) LoadError!void {
    const total_blocks = payload.len;
    try page_ops.ensureBlockCapacity(core, @intCast(total_blocks), side);
    const total_pages = (total_blocks + constants.EDGE_BLOCKS_PER_PAGE - 1) / constants.EDGE_BLOCKS_PER_PAGE;

    for (0..total_pages) |page_idx| {
        const start = page_idx * constants.EDGE_BLOCKS_PER_PAGE;
        const end = start + constants.EDGE_BLOCKS_PER_PAGE;
        const source_copy = payload[start..@min(end, payload.len)];
        const page_destination: [*]u8 = @ptrFromInt(page_ops.blockAlivePageRaw(
            core,
            @intCast(page_idx),
            side,
        ));
        @memcpy(page_destination, source_copy);
    }
}

pub fn restoreEdgeBlockIds(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    const block_size = @sizeOf(types.EdgeBlockFwdIds);
    const total_blocks = payload.len / block_size;

    try page_ops.ensureBlockCapacity(core, @intCast(total_blocks), .fwd);
    const total_pages = (total_blocks + constants.EDGE_BLOCKS_PER_PAGE - 1) / constants.EDGE_BLOCKS_PER_PAGE;

    for (0..total_pages) |page_idx| {
        const start = page_idx * constants.EDGE_BLOCKS_PER_PAGE * block_size;
        const end = start + (constants.EDGE_BLOCKS_PER_PAGE * block_size);
        const source_copy = payload[start..@min(end, payload.len)];
        const page_destination: [*]u8 = @ptrFromInt(page_ops.edgeBlockFwdIdsPageRaw(
            core,
            @intCast(page_idx),
        ));
        @memcpy(page_destination, source_copy);
    }
}

pub fn restoreEdgeBlockPropRows(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    const block_size = @sizeOf(types.EdgeBlockFwdProps);
    const total_blocks = payload.len / block_size;

    try page_ops.ensureBlockCapacity(core, @intCast(total_blocks), .fwd);
    const total_pages = (total_blocks + constants.EDGE_BLOCKS_PER_PAGE - 1) / constants.EDGE_BLOCKS_PER_PAGE;

    for (0..total_pages) |page_idx| {
        const start = page_idx * constants.EDGE_BLOCKS_PER_PAGE * block_size;
        const end = start + (constants.EDGE_BLOCKS_PER_PAGE * block_size);
        const source_copy = payload[start..@min(end, payload.len)];
        const page_destination: [*]u8 = @ptrFromInt(page_ops.edgeBlockFwdPropsPageRaw(
            core,
            @intCast(page_idx),
        ));
        @memcpy(page_destination, source_copy);
    }
}

pub fn restoreEdgeBlockSegments(core: *graph_core.GraphCore, payload: []const u8) LoadError!void {
    const segment_size = @sizeOf(types.EdgeBlockSegment);
    const total_segments = payload.len / segment_size;

    try page_ops.ensureSegmentCapacity(core, @intCast(total_segments));
    const total_pages = (total_segments + constants.EDGE_SEGMENTS_PER_PAGE - 1) / constants.EDGE_SEGMENTS_PER_PAGE;

    for (0..total_pages) |page_idx| {
        const start = page_idx * constants.EDGE_SEGMENTS_PER_PAGE * segment_size;
        const end = start + (constants.EDGE_SEGMENTS_PER_PAGE * segment_size);
        const source_copy = payload[start..@min(end, payload.len)];
        const page_destination: [*]u8 = @ptrFromInt(core.edge_block_segment_pages.load(@intCast(page_idx)));
        @memcpy(page_destination, source_copy);
    }
}

pub fn restoreTinySlots(core: *graph_core.GraphCore, payload: []const u8, comptime side: adjacency.AdjSide) LoadError!void {
    const block_size = switch (side) {
        .fwd => @sizeOf(node_tiny.TinyFwdSlot),
        .rev => @sizeOf(node_tiny.TinyRevSlot),
    };
    const per_page = switch (side) {
        .fwd => node_tiny.TINY_FWD_SLOTS_PER_PAGE,
        .rev => node_tiny.TINY_REV_SLOTS_PER_PAGE,
    };
    const total_blocks = payload.len / block_size;

    try page_ops.ensureTinyCapacity(core, @intCast(total_blocks), side);
    const total_pages = (total_blocks + per_page - 1) / per_page;

    for (0..total_pages) |page_idx| {
        const start = page_idx * per_page * block_size;
        const end = start + (per_page * block_size);
        const source_copy = payload[start..@min(end, payload.len)];
        const destination_raw = switch (side) {
            .fwd => core.tiny_fwd_slot_pages.load(@intCast(page_idx)),
            .rev => core.tiny_rev_slot_pages.load(@intCast(page_idx)),
        };
        const page_destination: [*]u8 = @ptrFromInt(destination_raw);
        @memcpy(page_destination, source_copy);
    }
}

/// Replays one NodeRecord into the live node pools: NodePublicationCell (degrees,
/// flags, fwd/idx_rev = 0, version 0), NodeAdjacencyBuffers (slot 0 = the
/// persisted SideAdj, sorted bits), NodeMutationControl (next_local_edge_id, claims
/// released). Every block/segment/tiny index inside the record is
/// bounds-checked against the header counters (CorruptIndex).
pub fn restoreNodeRecord(core: *graph_core.GraphCore, node_idx: u32, record: format.NodeRecord, header: format.FileHeader) LoadError!void {
    const node = types.NodeId{ .index = node_idx };
    const page_idx = node_idx / constants.NODES_PER_PAGE;

    // Ensure the three node pages exist for this node_idx.
    _ = try page_ops.ensureNodePublicationPage(core, page_idx);
    _ = try page_ops.ensureNodeAdjacencyBufferPage(core, page_idx);
    _ = try page_ops.ensureNodeMutationControlPage(core, page_idx);

    // 2. Write NodePublicationCell: fresh NodePublicationState with indexes at slot 0.
    var publication_state: types.NodePublicationState = .{
        .idx_fwd = 0,
        .idx_rev = 0,
        .needs_repair_fwd = record.flags.needs_repair_fwd,
        .needs_repair_rev = record.flags.needs_repair_rev,
        .removed = record.flags.removed,
        .version = 0,
    };
    publication_state = publication_state.withFwdDegree(record.degree_fwd).withRevDegree(record.degree_rev);
    page_ops.nodePublicationAt(core, node).storePublicationState(publication_state);

    // Write NodeAdjacencyBuffers: slot 0 = persisted SideAdj; slot 1 zeroed.
    const buffers = page_ops.nodeAdjacencyBuffersAt(core, node);
    buffers.fwd[0] = record.fwd;
    buffers.rev[0] = record.rev;
    buffers.fwd[1] = std.mem.zeroes(types.SideAdj);
    buffers.rev[1] = std.mem.zeroes(types.SideAdj);
    buffers.sorted_fwd[0] = @intFromBool(record.flags.sorted_fwd);
    buffers.sorted_rev[0] = @intFromBool(record.flags.sorted_rev);
    if (publication_state.degree_fwd_overflow) buffers.degrees_fwd[0] = record.degree_fwd;
    if (publication_state.degree_rev_overflow) buffers.degrees_rev[0] = record.degree_rev;

    // Write NodeMutationControl: next_local_edge_id; claims start released.
    page_ops.nodeMutationControlAt(core, node).storeNextLocalEdgeId(record.next_local_edge_id);

    // Bounds-check every block/segment/tiny index against header counters.
    try validateSideAdj(record.fwd, .fwd, header);
    try validateSideAdj(record.rev, .rev, header);
}

/// Pushes a persisted free list back onto its lock-free stack. Indices are
/// bounds-checked against the matching frontier counter first.
pub fn restoreFreeList(core: *graph_core.GraphCore, id: format.SectionId, payload: []const u8, header: format.FileHeader) LoadError!void {
    switch (id) {
        .free_blocks_fwd, .free_blocks_rev => {
            const side: adjacency.AdjSide = if (id == .free_blocks_fwd) .fwd else .rev;
            const limit: u32 = switch (side) {
                .fwd => header.block_fwd_count,
                .rev => header.block_rev_count,
            };
            const indices = std.mem.bytesAsSlice(u32, payload);
            for (indices) |idx| {
                if (idx >= limit) return error.CorruptIndex;
                switch (side) {
                    .fwd => page_ops.freeBlock(core, idx, .fwd),
                    .rev => page_ops.freeBlock(core, idx, .rev),
                }
            }
        },
        .free_tiny_fwd, .free_tiny_rev => {
            const side: adjacency.AdjSide = if (id == .free_tiny_fwd) .fwd else .rev;
            const limit: u32 = switch (side) {
                .fwd => header.tiny_fwd_slot_count,
                .rev => header.tiny_rev_slot_count,
            };
            const indices = std.mem.bytesAsSlice(u32, payload);
            for (indices) |idx| {
                if (idx >= limit) return error.CorruptIndex;
                switch (side) {
                    .fwd => page_ops.freeTinySlot(core, idx, .fwd),
                    .rev => page_ops.freeTinySlot(core, idx, .rev),
                }
            }
        },
        .free_segment_slots => {
            const segment_descriptors = std.mem.bytesAsSlice(format.FreeSegmentSlots, payload);
            for (segment_descriptors) |slot_entry| {
                if (slot_entry.slot_count == 0) return error.CorruptIndex;
                const last_segment = std.math.add(u32, slot_entry.first_segment, slot_entry.slot_count - 1) catch return error.CorruptIndex;
                if (last_segment >= header.segment_count) return error.CorruptIndex;
                page_ops.freeSegmentSlots(core, slot_entry.first_segment, slot_entry.slot_count);
            }
        },
        .free_prop_rows => {
            const rows = std.mem.bytesAsSlice(u32, payload);
            for (rows) |row| {
                if (row >= header.prop_row_count) return error.CorruptIndex;
                page_ops.freePropRow(core, row);
            }
        },
        else => {},
    }
}

// ── Internal helpers ───────────────────────────────────────────────────

/// Bounds-checks every block, segment, and tiny index inside `side_adj`
/// against the header's pool counters. Returns `error.CorruptIndex` if any
/// index is out of range or if arithmetic overflows (hostile input).
fn validateSideAdj(side_adj: types.SideAdj, side: adjacency.AdjSide, header: format.FileHeader) error{CorruptIndex}!void {
    if (node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&side_adj)) {
        const block_idx = side_adj.first_block;
        const limit = switch (side) {
            .fwd => header.tiny_fwd_slot_count,
            .rev => header.tiny_rev_slot_count,
        };
        if (block_idx >= limit) return error.CorruptIndex;
        return;
    }

    if (side_adj.block_count > 0) {
        const limit = switch (side) {
            .fwd => header.block_fwd_count,
            .rev => header.block_rev_count,
        };
        const last_block = std.math.add(u32, side_adj.first_block, side_adj.block_count - 1) catch return error.CorruptIndex;
        if (last_block >= limit) return error.CorruptIndex;
    }

    if (side_adj.segment_count > 0) {
        const last_segment = std.math.add(u32, side_adj.first_segment, side_adj.segment_count - 1) catch return error.CorruptIndex;
        if (last_segment >= header.segment_count) return error.CorruptIndex;
    }
}
