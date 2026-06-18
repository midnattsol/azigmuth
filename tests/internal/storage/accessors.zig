//! Direct coverage for storage-level accessors that have no other callers
//! yet (tiny slot editing, node bitmaps, radix capacity, published-degree
//! pointers, dynamic slot reads). Keeping them instantiated here means a
//! layout change cannot silently break them.

const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;
const tiny = graph_mod.tiny_mod;
const node_bitmap = graph_mod.node_bitmap_mod;
const node_access = graph_mod.node_access_mod;
const node_adjacency_buffers = graph_mod.node_adjacency_buffers_mod;
const side_ops = graph_mod.side_ops_mod;

const testing = std.testing;

const no_flags: types.EdgeFlags = @bitCast(@as(u16, 0));

test "tiny: fwdCap depends on multigraph mode" {
    try testing.expectEqual(@as(u16, 8), tiny.fwdCap(false));
    try testing.expectEqual(@as(u16, 4), tiny.fwdCap(true));
}

test "tiny: removeFwd shifts the tail down and clears the freed entry" {
    var slot = tiny.TinyFwdSlot{};
    var count: u16 = 0;
    count = try tiny.insertFwd(&slot, count, 10, 1, no_flags, 1, 0, false);
    count = try tiny.insertFwd(&slot, count, 20, 2, no_flags, 2, 0, false);
    count = try tiny.insertFwd(&slot, count, 30, 3, no_flags, 3, 0, false);

    // Miss leaves the slot untouched.
    try testing.expectEqual(@as(?u16, null), tiny.removeFwd(&slot, count, 99, null, false));

    count = tiny.removeFwd(&slot, count, 20, null, false) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 2), count);
    try testing.expectEqual(@as(u32, 10), slot.entries[0].destination);
    try testing.expectEqual(@as(u32, 30), slot.entries[1].destination);
    try testing.expectEqual(@as(u16, 3), slot.entries[1].relation);
    try testing.expectEqual(@as(u32, 0), slot.entries[2].destination);
}

test "tiny: removeFwd in multigraph mode matches on edge id" {
    var slot = tiny.TinyFwdSlot{};
    var count: u16 = 0;
    count = try tiny.insertFwd(&slot, count, 10, 0, no_flags, 7, 0, true);
    count = try tiny.insertFwd(&slot, count, 10, 0, no_flags, 9, 0, true);

    // Wrong edge id is a miss; the right one removes only that parallel edge.
    try testing.expectEqual(@as(?u16, null), tiny.removeFwd(&slot, count, 10, 5, true));
    count = tiny.removeFwd(&slot, count, 10, 7, true) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 1), count);
    try testing.expectEqual(@as(u32, 9), slot.entries[0].edge_id);
}

test "tiny: removeRev shifts sources down" {
    var slot = tiny.TinyRevSlot{};
    var count: u16 = 0;
    count = tiny.insertRev(&slot, count, 5);
    count = tiny.insertRev(&slot, count, 15);
    count = tiny.insertRev(&slot, count, 25);

    try testing.expectEqual(@as(?u16, null), tiny.removeRev(&slot, count, 99));

    count = tiny.removeRev(&slot, count, 5) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 2), count);
    try testing.expectEqual(@as(u32, 15), slot.sources[0]);
    try testing.expectEqual(@as(u32, 25), slot.sources[1]);
}

test "node_bitmap: ensurePageForNode, setBit and clearBit round-trip" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const directory = &graph.graph.repair_queued_fwd_pages;
    const node_idx: u32 = 123;

    try node_bitmap.ensurePageForNode(&graph.graph, directory, node_idx);
    try testing.expect(!node_bitmap.isSet(directory, node_idx));

    try node_bitmap.setBit(&graph.graph, directory, node_idx);
    try testing.expect(node_bitmap.isSet(directory, node_idx));
    // Neighboring bits stay untouched.
    try testing.expect(!node_bitmap.isSet(directory, node_idx - 1));
    try testing.expect(!node_bitmap.isSet(directory, node_idx + 1));

    try node_bitmap.clearBit(&graph.graph, directory, node_idx);
    try testing.expect(!node_bitmap.isSet(directory, node_idx));
}

test "radix directory: maxPages reports the inline + L1*L2 capacity" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const dims = constants.NODE_DIR;
    const expected: usize = dims.inline_pages + dims.l1 * dims.l2;
    try testing.expectEqual(expected, graph.graph.repair_queued_fwd_pages.maxPages());
}

test "published degrees: pointer accessors read the live published slot" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const source_buffers = node_access.nodeAdjacencyBuffersAt(&graph.graph, source);
    const source_state = node_access.loadPublicationStateAtConst(&graph.graph, source);
    try testing.expectEqual(@as(u32, 1), source_buffers.publishedFwdDegree(source_state).*);
    try testing.expectEqual(@as(u32, 0), source_buffers.publishedRevDegree(source_state).*);

    const destination_buffers = node_access.nodeAdjacencyBuffersAt(&graph.graph, destination);
    const destination_state = node_access.loadPublicationStateAtConst(&graph.graph, destination);
    try testing.expectEqual(@as(u32, 0), destination_buffers.publishedFwdDegree(destination_state).*);
    try testing.expectEqual(@as(u32, 1), destination_buffers.publishedRevDegree(destination_state).*);
}

test "NodeRef: publishedFwd/publishedRev expose the per-side descriptors" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    const source_ref = try graph.nodeAt(source);
    const source_fwd = source_ref.publishedFwd();
    try testing.expect(node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&source_fwd));
    try testing.expectEqual(@as(u16, 1), node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&source_fwd));

    const destination_ref = try graph.nodeAt(destination);
    const destination_rev = destination_ref.publishedRev();
    try testing.expect(node_adjacency_buffers.NodeAdjacencyBuffers.isTiny(&destination_rev));
    try testing.expectEqual(@as(u16, 1), node_adjacency_buffers.NodeAdjacencyBuffers.tinyCount(&destination_rev));

    const source_rev = source_ref.publishedRev();
    try testing.expectEqual(@as(u32, 0), source_rev.block_count);
}

test "side_ops: readNodeIdAtSlotDynamic reads both sides with a runtime side" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    var nodes: [4]graph_mod.NodeId = undefined;
    for (0..nodes.len) |node_idx| nodes[node_idx] = try graph.addNode();

    const blk_f = try graph.allocBlockFwd();
    const bf = page_ops.edgeBlockAt(&graph.graph, blk_f, .fwd);
    for (0..3) |slot| {
        bf.destinations[slot] = nodes[slot].index;
        bf.relations[slot] = 0;
        bf.flags[slot] = 0;
    }
    page_ops.setBlockAliveCount(&graph.graph, blk_f, .fwd, 3);

    const blk_r = try graph.allocBlockRev();
    const br = page_ops.edgeBlockAt(&graph.graph, blk_r, .rev);
    for (0..3) |slot| br.sources[slot] = nodes[3 - slot - 1].index;
    page_ops.setBlockAliveCount(&graph.graph, blk_r, .rev, 3);

    const sides = [_]struct { side: graph_mod.adjacency_mod.AdjSide, block: u32, slot: u7, expected: u32 }{
        .{ .side = .fwd, .block = blk_f, .slot = 0, .expected = nodes[0].index },
        .{ .side = .fwd, .block = blk_f, .slot = 2, .expected = nodes[2].index },
        .{ .side = .rev, .block = blk_r, .slot = 0, .expected = nodes[2].index },
        .{ .side = .rev, .block = blk_r, .slot = 2, .expected = nodes[0].index },
    };
    for (sides) |side_case| {
        try testing.expectEqual(side_case.expected, side_ops.readNodeIdAtSlotDynamic(&graph.graph, side_case.block, side_case.slot, side_case.side));
    }
}

test "radix directory: lazy levels publish pages across the inline boundary" {
    const Dir = graph_mod.radix_directory_mod.RadixDirectory(2, 4, 8);
    var dir = Dir{};
    defer dir.deinitLeaves(testing.allocator);

    try testing.expectEqual(@as(usize, 0), dir.load(0));
    try testing.expectEqual(@as(usize, 0), dir.load(@intCast(Dir.max_pages - 1)));

    // Inline page: no heap level involved.
    (try dir.slotPtr(testing.allocator, 1)).store(0x1000, .release);
    try testing.expectEqual(@as(usize, 0x1000), dir.load(1));

    // First page past the inline window forces root + leaf allocation.
    (try dir.slotPtr(testing.allocator, 2)).store(0x2000, .release);
    try testing.expectEqual(@as(usize, 0x2000), dir.load(2));

    // Last addressable page lands in the last leaf.
    const last_page: u32 = @intCast(Dir.max_pages - 1);
    (try dir.slotPtr(testing.allocator, last_page)).store(0x3000, .release);
    try testing.expectEqual(@as(usize, 0x3000), dir.load(last_page));

    // Beyond capacity: load reports absent, slotPtr fails cleanly.
    try testing.expectEqual(@as(usize, 0), dir.load(@intCast(Dir.max_pages)));
    try testing.expectError(error.OutOfMemory, dir.slotPtr(testing.allocator, @intCast(Dir.max_pages)));
}

test "radix directory: node growth crosses the inline page window" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    // Default profile keeps 4 inline node pages (1024 nodes); go past them.
    const total: u32 = 4 * 256 + 64;
    var last: graph_mod.NodeId = undefined;
    for (0..total) |_| last = try graph.addNode();
    try testing.expectEqual(@as(usize, total), graph.nodeCount());

    const first = graph_mod.NodeId{ .index = 0 };
    try graph.addEdge(first, last, 0, 0);
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(first));
    try testing.expectEqual(@as(usize, 1), try graph.inDegree(last));
    try graph.validate();
}

test "default profile: GraphCore fixed footprint stays bounded" {
    try testing.expect(@sizeOf(graph_mod.GraphCore) < 16 * 1024);
}

test "frontier rollback: removal churn does not grow the block pool unboundedly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var destinations: [512]graph_mod.NodeId = undefined;
    for (0..destinations.len) |destination_idx| destinations[destination_idx] = try graph.addNode();

    var frontier_after_first_cycle: u32 = 0;
    for (0..6) |cycle| {
        for (destinations) |destination| {
            try graph.addEdge(source, destination, 0, 0);
        }
        for (destinations) |destination| {
            _ = graph.removeEdge(source, destination) catch |err| switch (err) {
                error.RepairRequired => blk: {
                    _ = try graph.repairNode(source);
                    break :blk try graph.removeEdge(source, destination);
                },
                else => return err,
            };
        }
        graph.reclaimRetired();
        const stats = try graph.storageStats();
        if (cycle == 0) frontier_after_first_cycle = stats.blocks_fwd_allocated;
        // After reclaim + rollback the frontier must stay bounded instead of
        // accumulating one fresh slot_entry set per cycle.
        try testing.expect(stats.blocks_fwd_allocated <= frontier_after_first_cycle * 2);
    }
    try graph.validate();
}

test "persistence format: header round-trips through its own validators" {
    const persistence = graph_mod.persistence_mod;

    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);

    var raw_header: [persistence.HEADER_BYTES]u8 = @splat(0);
    var header = persistence.FileHeader.init(&graph.graph);
    @memcpy(raw_header[0..@sizeOf(persistence.FileHeader)], std.mem.asBytes(&header));
    header.header_checksum = persistence.headerChecksum(&raw_header);
    @memcpy(raw_header[0..@sizeOf(persistence.FileHeader)], std.mem.asBytes(&header));

    try persistence.validateHeader(header, &raw_header);
    try testing.expectEqual(@as(u64, 2), header.node_count);
    try testing.expectEqual(@as(u64, 1), header.edge_count);
    try testing.expect(!header.flags.multigraph);

    // Tampering must be caught.
    var bad = header;
    bad.magic +%= 1;
    try testing.expectError(error.BadMagic, persistence.validateHeader(bad, &raw_header));
    bad = header;
    bad.params.edges_per_block +%= 1;
    try testing.expectError(error.IncompatibleFormatParams, persistence.validateHeader(bad, &raw_header));
    raw_header[100] +%= 1;
    try testing.expectError(error.CorruptHeader, persistence.validateHeader(header, &raw_header));
}

test "persistence format: a well-formed section table validates; misaligned or overlapping does not" {
    const persistence = graph_mod.persistence_mod;

    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();
    const source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(source, destination, 0, 0);
    const header = persistence.FileHeader.init(&graph.graph);

    var table: [persistence.MAX_SECTIONS]persistence.SectionDescriptor = undefined;
    var offset: u64 = persistence.PAYLOAD_BASE_OFFSET;
    for (0..persistence.MAX_SECTIONS) |section_idx| {
        const id: persistence.SectionId = @enumFromInt(section_idx);
        const byte_len = persistence.expectedSectionBytes(header, id) orelse 0;
        table[section_idx] = .{
            .id = @intCast(section_idx),
            .entry_count = if (byte_len == 0) 0 else 1,
            .file_offset = offset,
            .byte_len = byte_len,
            .checksum = 0,
        };
        // entry_count is only validated for the free-list sections.
        if (persistence.expectedSectionBytes(header, id) == null) table[section_idx].entry_count = 0;
        if (table[section_idx].byte_len == 0) table[section_idx].entry_count = 0;
        offset = persistence.alignForward(@intCast(offset + byte_len), persistence.SECTION_ALIGN);
    }
    try persistence.validateSectionTable(header, &table);

    // Misaligned payload offset must fail (node_records is never empty here).
    var bad_table = table;
    bad_table[0].file_offset += 1;
    try testing.expectError(error.CorruptSectionTable, persistence.validateSectionTable(header, &bad_table));

    // Wrong derived size must fail.
    bad_table = table;
    bad_table[0].byte_len += 64;
    try testing.expectError(error.CorruptSectionTable, persistence.validateSectionTable(header, &bad_table));
}
