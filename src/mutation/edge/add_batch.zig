//! Batched edge insertion: one claim cycle, one source-side rebuild, and one
//! publish per touched node instead of per edge. Follows RFC §5.2 discipline
//! scaled to a batch: every fallible step (claims, duplicate checks, storage
//! allocation, side construction) happens before the first publish; the
//! publish loop itself cannot fail, so a mid-batch error never leaves the
//! forward/reverse bijection broken.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const node_access = @import("../../core/node_access.zig");
const node_published_mod = @import("../../storage/node/published.zig");
const node_tiny = @import("../../storage/node/tiny.zig");
const page_ops = @import("../../storage/page_ops.zig");
const types = @import("../../core/types.zig");
const adjacency = @import("../../adjacency/mod.zig");
const side_ops = @import("../../adjacency/side_ops.zig");
const rcu = @import("../../concurrency/rcu.zig");
const common = @import("../common.zig");
const claims_mod = @import("../claims.zig");
const node_validity = @import("../../core/node_validity.zig");
const publish_mod = @import("../publish.zig");

pub const EdgeInput = types.EdgeInput;

const SortedInput = struct {
    destination_idx: u32,
    relation: u16,
    flags: u16,
    edge_id: u32 = 0,
    prop_row: u32 = 0,
};

fn inputLessThan(_: void, lhs: SortedInput, rhs: SortedInput) bool {
    if (lhs.destination_idx != rhs.destination_idx) return lhs.destination_idx < rhs.destination_idx;
    return lhs.edge_id < rhs.edge_id;
}

const FwdEntry = struct {
    destination_idx: u32,
    relation: u16,
    flags: u16,
    edge_id: u32,
    prop_row: u32 = 0,
};

fn fwdEntryLessThan(_: void, lhs: FwdEntry, rhs: FwdEntry) bool {
    if (lhs.destination_idx != rhs.destination_idx) return lhs.destination_idx < rhs.destination_idx;
    return lhs.edge_id < rhs.edge_id;
}

const DestinationPlan = struct {
    destination_idx: u32,
    added: u32,
    claims: claims_mod.ClaimedNodeSides,
    new_side: types.SideAdj,
    old_side: types.SideAdj,
};

fn buildForwardSide(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    published_side: types.SideAdj,
    batch: []const SortedInput,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    const Gather = struct {
        entries: *std.ArrayList(FwdEntry),
        allocator: std.mem.Allocator,
    };
    var entries: std.ArrayList(FwdEntry) = .empty;
    defer entries.deinit(graph.allocator);
    var gather = Gather{ .entries = &entries, .allocator = graph.allocator };
    try side_ops.forEachForwardEntryInSide(graph, published_side, &gather, struct {
        fn run(_: *const graph_core.GraphCore, context: *Gather, entry: side_ops.ForwardEntryView) !void {
            try context.entries.append(context.allocator, .{
                .destination_idx = entry.destination,
                .relation = entry.relation,
                .flags = @bitCast(entry.flags),
                .edge_id = entry.edge_id,
                .prop_row = entry.prop_row,
            });
        }
    }.run);
    for (batch) |input| {
        try entries.append(graph.allocator, .{
            .destination_idx = input.destination_idx,
            .relation = input.relation,
            .flags = input.flags,
            .edge_id = input.edge_id,
            .prop_row = input.prop_row,
        });
    }
    std.sort.pdq(FwdEntry, entries.items, {}, fwdEntryLessThan);

    const total = entries.items.len;
    if (total > constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    // Small result: keep the tiny representation.
    const tiny_cap: usize = if (graph.multigraph_enabled) @import("../../core/tiny_config.zig").TINY_FWD_CAP_MULTI else @import("../../core/tiny_config.zig").TINY_FWD_CAP_SIMPLE;
    if (total <= tiny_cap) {
        const slot_idx = try scratch.allocTinySlotRaw(graph, .fwd);
        const slot = page_ops.tinyFwdAt(graph, slot_idx);
        for (entries.items, 0..) |entry, entry_idx| {
            slot.entries[entry_idx] = .{
                .destination = entry.destination_idx,
                .relation = entry.relation,
                .flags = @bitCast(entry.flags),
                .edge_id = entry.edge_id,
                .prop_row = entry.prop_row,
            };
        }
        return node_published_mod.NodePublished.makeTiny(slot_idx, @intCast(total));
    }

    const span_count: u32 = @intCast((total + constants.EDGES_PER_BLOCK - 1) / constants.EDGES_PER_BLOCK);
    if (span_count > constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;
    const first_block_idx = try scratch.allocFreshBlockSpan(graph, .fwd, span_count);

    var remaining = entries.items;
    var emit_block_idx = first_block_idx;
    while (remaining.len > 0) : (emit_block_idx += 1) {
        const take = @min(remaining.len, constants.EDGES_PER_BLOCK);
        const block = page_ops.edgeBlockAt(graph, emit_block_idx, .fwd);
        const id_block = if (graph.multigraph_enabled) page_ops.edgeBlockFwdIdsAt(graph, emit_block_idx) else undefined;
        const prop_block = if (graph.edge_properties_enabled) page_ops.edgeBlockFwdPropsAt(graph, emit_block_idx) else undefined;
        for (remaining[0..take], 0..) |entry, slot| {
            block.destinations[slot] = entry.destination_idx;
            block.relations[slot] = entry.relation;
            block.flags[slot] = entry.flags;
            if (graph.multigraph_enabled) id_block.ids[slot] = entry.edge_id;
            if (graph.edge_properties_enabled) prop_block.rows[slot] = entry.prop_row;
        }
        page_ops.setBlockLiveCount(graph, emit_block_idx, .fwd, @intCast(take));
        remaining = remaining[take..];
    }
    _ = source;
    return .{ .first_block = first_block_idx, .block_count = span_count, .group_count = 0, .first_group = 0 };
}

fn buildReverseSide(
    graph: *graph_core.GraphCore,
    source: types.NodeId,
    published_side: types.SideAdj,
    added: u32,
    scratch: *common.MutationScratch,
) !types.SideAdj {
    // Fast path for the dominant fan-out shape: previously isolated
    // destination, few incoming copies — fill a tiny slot directly.
    if (published_side.block_count == 0 and added <= @import("../../core/tiny_config.zig").TINY_REV_CAP) {
        const slot_idx = try scratch.allocTinySlotRaw(graph, .rev);
        const slot = page_ops.tinyRevAt(graph, slot_idx);
        for (0..added) |entry_idx| slot.sources[entry_idx] = source.index;
        return node_published_mod.NodePublished.makeTiny(slot_idx, @intCast(added));
    }

    var sources: std.ArrayList(u32) = .empty;
    defer sources.deinit(graph.allocator);
    const Gather = struct {
        sources: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
    };
    var gather = Gather{ .sources = &sources, .allocator = graph.allocator };
    if (published_side.block_count != 0) {
        try side_ops.forEachNodeIdInSide(graph, published_side, .rev, &gather, struct {
            fn run(_: *const graph_core.GraphCore, context: *Gather, source_idx: u32) !void {
                try context.sources.append(context.allocator, source_idx);
            }
        }.run);
    }
    for (0..added) |_| try sources.append(graph.allocator, source.index);
    std.sort.pdq(u32, sources.items, {}, std.sort.asc(u32));

    const total = sources.items.len;
    if (total > constants.MAX_DEGREE_PER_SIDE) return error.DegreeLimitReached;

    if (total <= @import("../../core/tiny_config.zig").TINY_REV_CAP) {
        const slot_idx = try scratch.allocTinySlotRaw(graph, .rev);
        const slot = page_ops.tinyRevAt(graph, slot_idx);
        for (sources.items, 0..) |source_idx, entry_idx| slot.sources[entry_idx] = source_idx;
        return node_published_mod.NodePublished.makeTiny(slot_idx, @intCast(total));
    }

    const span_count: u32 = @intCast((total + constants.EDGES_PER_BLOCK - 1) / constants.EDGES_PER_BLOCK);
    if (span_count > constants.MAX_BLOCKS_PER_SIDE) return error.BlockLimitReached;
    const first_block_idx = try scratch.allocFreshBlockSpan(graph, .rev, span_count);

    var remaining = sources.items;
    var emit_block_idx = first_block_idx;
    while (remaining.len > 0) : (emit_block_idx += 1) {
        const take = @min(remaining.len, constants.EDGES_PER_BLOCK);
        const block = page_ops.edgeBlockAt(graph, emit_block_idx, .rev);
        for (remaining[0..take], 0..) |source_idx, slot| block.sources[slot] = source_idx;
        page_ops.setBlockLiveCount(graph, emit_block_idx, .rev, @intCast(take));
        remaining = remaining[take..];
    }
    return .{ .first_block = first_block_idx, .block_count = span_count, .group_count = 0, .first_group = 0 };
}

fn retireSideStorage(graph: *graph_core.GraphCore, side: types.SideAdj, comptime which: adjacency.AdjSide) !void {
    if (side.block_count == 0) return;
    var adj = std.mem.zeroes(types.NodeAdj);
    side_ops.writeSide(&adj, which, side);
    try common.retireSide(graph, adj, which);
}

/// Adds a batch of edges from one source. All-or-nothing: on error the graph
/// is unchanged. Returns the number of edges added (== edges.len on success).
pub fn addEdges(graph: *graph_core.GraphCore, source: types.NodeId, edges: []const types.EdgeInput) !usize {
    if (edges.len == 0) return 0;
    if (!node_validity.nodeExistsRaw(graph, source)) return error.InvalidNode;

    var writer_guard = common.beginWriter(graph);
    defer writer_guard.end();

    var scratch = common.MutationScratch{};
    defer scratch.deinit(graph.allocator);
    defer scratch.cleanup(graph);

    // ── Phase A: everything fallible ─────────────────────────────────

    const batch = try graph.allocator.alloc(SortedInput, edges.len);
    defer graph.allocator.free(batch);
    for (edges, 0..) |edge, edge_idx| {
        if (!node_validity.nodeExistsRaw(graph, edge.destination)) return error.InvalidNode;
        batch[edge_idx] = .{
            .destination_idx = edge.destination.index,
            .relation = edge.relation,
            .flags = @bitCast(edge.flags),
        };
    }

    // Claim the source forward side first.
    const source_hot = page_ops.nodeHotAt(graph, source);
    try source_hot.claimFwd();
    defer source_hot.releaseFwd();

    const source_meta = node_access.loadPublishedMetaAtConst(graph, source);
    if (source_meta.removed) return error.InvalidNode;
    const source_pub = node_access.publishedFwdFromMeta(graph, source, source_meta);
    const source_sorted = node_access.nodePublishedAtConst(graph, source).publishedFwdSortedFromMeta(source_meta);

    // Duplicate rejection (simple mode): intra-batch and against the graph.
    if (!graph.multigraph_enabled) {
        std.sort.pdq(SortedInput, batch, {}, inputLessThan);
        for (batch, 0..) |input, batch_idx| {
            if (batch_idx > 0 and batch[batch_idx - 1].destination_idx == input.destination_idx) return error.EdgeAlreadyExists;
            if (try adjacency.hasEdgeInSideAdjChecked(graph, source_pub, input.destination_idx, source_sorted)) return error.EdgeAlreadyExists;
        }
    } else {
        for (batch) |*input| input.edge_id = (try source_hot.nextEdgeId()).local;
        std.sort.pdq(SortedInput, batch, {}, inputLessThan);
    }

    // Stable property rows for the new edges; freed by scratch cleanup if any
    // later fallible step rejects the batch.
    if (graph.edge_properties_enabled) {
        for (batch) |*input| input.prop_row = try scratch.allocPropRow(graph);
    }

    // Group by destination and claim every reverse side. Claims fail fast on
    // contention; everything claimed so far is released by the defers.
    var plans: std.ArrayList(DestinationPlan) = .empty;
    defer plans.deinit(graph.allocator);
    defer for (plans.items) |*plan| plan.claims.release();

    var batch_pos: usize = 0;
    while (batch_pos < batch.len) {
        const destination_idx = batch[batch_pos].destination_idx;
        var added: u32 = 0;
        while (batch_pos < batch.len and batch[batch_pos].destination_idx == destination_idx) : (batch_pos += 1) added += 1;

        const want_rev = true;
        var node_claims = if (destination_idx == source.index)
            claims_mod.ClaimedNodeSides{ .hot = source_hot }
        else
            try claims_mod.tryClaimNodeSides(graph, destination_idx, false, want_rev);
        errdefer node_claims.release();
        if (destination_idx == source.index) try node_claims.ensureRev();

        const destination_meta = node_access.loadPublishedMetaAtConst(graph, .{ .index = destination_idx });
        if (destination_meta.removed) {
            node_claims.release();
            return error.InvalidNode;
        }
        const old_side = node_access.publishedRevFromMeta(graph, .{ .index = destination_idx }, destination_meta);
        try plans.append(graph.allocator, .{
            .destination_idx = destination_idx,
            .added = added,
            .claims = node_claims,
            .new_side = undefined,
            .old_side = old_side,
        });
    }

    // Build all replacement sides while everything is still revocable.
    const new_source_side = try buildForwardSide(graph, source, source_pub, batch, &scratch);
    for (plans.items) |*plan| {
        plan.new_side = try buildReverseSide(graph, source, plan.old_side, plan.added, &scratch);
    }

    // ── Phase B: publish (infallible) ────────────────────────────────

    scratch.disarm();

    for (plans.items) |plan| {
        const destination: types.NodeId = .{ .index = plan.destination_idx };
        const destination_meta = node_access.loadPublishedMetaAtConst(graph, destination);
        node_access.writeStagingRev(graph, destination, destination_meta, plan.new_side);
        _ = publish_mod.publishStagedRev(
            page_ops.nodeMetaAt(graph, destination),
            page_ops.nodePublishedAt(graph, destination),
            destination_meta,
            destination_meta.needs_repair_rev,
            @intCast(plan.added),
            true,
        );
    }

    const fresh_source_meta = node_access.loadPublishedMetaAtConst(graph, source);
    node_access.writeStagingFwd(graph, source, fresh_source_meta, new_source_side);
    _ = publish_mod.publishStagedFwd(
        page_ops.nodeMetaAt(graph, source),
        page_ops.nodePublishedAt(graph, source),
        fresh_source_meta,
        fresh_source_meta.needs_repair_fwd,
        @intCast(edges.len),
        true,
    );

    _ = graph.edge_count.fetchAdd(@intCast(edges.len), .release);

    // Retire every superseded side wholesale: the rebuilds emitted fresh
    // storage, so nothing in the old sides is shared.
    try retireSideStorage(graph, source_pub, .fwd);
    for (plans.items) |plan| try retireSideStorage(graph, plan.old_side, .rev);

    rcu.bumpEpoch(graph);
    writer_guard.end();
    return edges.len;
}
