//! Debug validation — exhaustive check with allocation for detailed v.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const page_ops = @import("../../storage/page_ops.zig");
const rcu = @import("../../rcu.zig");
const adjacency_mod = @import("../../adjacency.zig");
const node_validity = @import("../../core/node_validity.zig");
const common = @import("common.zig");
const sums = @import("sums.zig");
const consistency = @import("consistency.zig");
const v = @import("violations.zig");

pub fn debugValidate(graph: *const graph_core.GraphCore, allocator: std.mem.Allocator) ![]types.Violation {
    const reader_token = try common.readerEnter(graph);
    defer common.readerExit(graph, reader_token);

    var list: std.ArrayList(types.Violation) = .empty;
    errdefer list.deinit(allocator);
    var total_visible_fwd: u64 = 0;
    var total_visible_rev: u64 = 0;

    var owned_forward_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire));
    defer owned_forward_blocks.deinit(allocator);
    var owned_reverse_blocks = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire));
    defer owned_reverse_blocks.deinit(allocator);

    var free_forward_blocks = try v.buildFreeBlockSet(graph, allocator, .fwd);
    defer free_forward_blocks.deinit(allocator);
    var free_reverse_blocks = try v.buildFreeBlockSet(graph, allocator, .rev);
    defer free_reverse_blocks.deinit(allocator);
    var retired_forward_blocks = try v.buildRetiredBlockSet(graph, allocator, .fwd);
    defer retired_forward_blocks.deinit(allocator);
    var retired_reverse_blocks = try v.buildRetiredBlockSet(graph, allocator, .rev);
    defer retired_reverse_blocks.deinit(allocator);

    const group_limit = @atomicLoad(u32, @constCast(&graph.group_count), .acquire);
    var owned_groups_debug = try std.DynamicBitSetUnmanaged.initEmpty(allocator, group_limit);
    defer owned_groups_debug.deinit(allocator);
    var free_groups_debug = try v.buildFreeGroupSet(graph, allocator);
    defer free_groups_debug.deinit(allocator);
    var retired_groups_debug = try v.buildRetiredGroupSet(graph, allocator);
    defer retired_groups_debug.deinit(allocator);

    const node_count = graph.publishedNodeCount();

    for (0..node_count) |node_index| {
        const node_id: u32 = @intCast(node_index);
        const adjacency = page_ops.nodeAtConst(graph, .{ .index = node_id }).publishedAdj();

        var forward_blocks: std.ArrayList(common.TraversedBlock) = .empty;
        defer forward_blocks.deinit(allocator);
        var reverse_blocks: std.ArrayList(common.TraversedBlock) = .empty;
        defer reverse_blocks.deinit(allocator);

        try v.collectAdjacencyBlocks(graph, allocator, &list, node_id, adjacency, &forward_blocks, .fwd);
        try v.collectAdjacencyBlocks(graph, allocator, &list, node_id, adjacency, &reverse_blocks, .rev);

        if (forward_blocks.items.len != adjacency.block_count_fwd) {
            try list.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = adjacency.block_count_fwd, .actual = @intCast(forward_blocks.items.len) } });
        }
        if (reverse_blocks.items.len != adjacency.block_count_rev) {
            try list.append(allocator, .{ .block_count_group_mismatch = .{ .node = node_id, .declared = adjacency.block_count_rev, .actual = @intCast(reverse_blocks.items.len) } });
        }

        if (adjacency.group_count_fwd > 0) {
            var group_idx = adjacency.first_group_fwd;
            var visited_groups: u32 = 0;
            while (group_idx != constants.END_OF_CHAIN and visited_groups < adjacency.group_count_fwd) : (visited_groups += 1) {
                if (group_idx >= group_limit) {
                    try list.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_idx } });
                    break;
                }
                if (owned_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .block_double_owned = .{ .block = group_idx } });
                }
                owned_groups_debug.set(group_idx);
                if (free_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = group_idx } });
                }
                if (retired_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .retired_block_reachable = .{ .block = group_idx, .node = node_id } });
                }
                group_idx = page_ops.groupAtConst(graph, group_idx).next;
            }
            if (visited_groups != adjacency.group_count_fwd) {
                try list.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = adjacency.first_group_fwd } });
            }
        }
        if (adjacency.group_count_rev > 0) {
            var group_idx = adjacency.first_group_rev;
            var visited_groups: u32 = 0;
            while (group_idx != constants.END_OF_CHAIN and visited_groups < adjacency.group_count_rev) : (visited_groups += 1) {
                if (group_idx >= group_limit) {
                    try list.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = group_idx } });
                    break;
                }
                if (owned_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .block_double_owned = .{ .block = group_idx } });
                }
                owned_groups_debug.set(group_idx);
                if (free_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .block_orphaned_in_free_list = .{ .block = group_idx } });
                }
                if (retired_groups_debug.isSet(group_idx)) {
                    try list.append(allocator, .{ .retired_block_reachable = .{ .block = group_idx, .node = node_id } });
                }
                group_idx = page_ops.groupAtConst(graph, group_idx).next;
            }
            if (visited_groups != adjacency.group_count_rev) {
                try list.append(allocator, .{ .blockgroup_chain_cycle = .{ .node = node_id, .group = adjacency.first_group_rev } });
            }
        }

        try v.appendOwnershipAndShapeViolations(graph, allocator, &list, &owned_forward_blocks, &free_forward_blocks, &retired_forward_blocks, node_id, forward_blocks.items, .fwd);
        try v.appendOwnershipAndShapeViolations(graph, allocator, &list, &owned_reverse_blocks, &free_reverse_blocks, &retired_reverse_blocks, node_id, reverse_blocks.items, .rev);
        try consistency.appendForwardConsistencyViolations(graph, allocator, &list, node_id, forward_blocks.items);
        try consistency.appendReverseConsistencyViolations(graph, allocator, &list, node_id, reverse_blocks.items);

        if (!adjacency.flags.removed) {
            for (forward_blocks.items) |block| {
                total_visible_fwd += sums.countVisibleEntriesInBlock(graph, block.block_index, .fwd);
            }
            for (reverse_blocks.items) |block| {
                total_visible_rev += sums.countVisibleEntriesInBlock(graph, block.block_index, .rev);
            }
        }

        // RFC §2.5: published exact degree consistency. Removed nodes are exempt:
        // their reverse side may retain residual tombstoned structure that
        // does not contribute to the public logical degree.
        const node_buffer = page_ops.nodeAtConst(graph, .{ .index = node_id });
        const meta = node_buffer.loadPublishedMeta();
        if (!adjacency.flags.removed) {
            const live_fwd: usize = @intCast(sums.sumVisibleAdjacency(graph, adjacency, .fwd));
            const pub_fwd: u22 = meta.degree_fwd;
            if (@as(usize, pub_fwd) != live_fwd) {
                try list.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(live_fwd), .actual = pub_fwd } });
            }
            const live_rev: usize = @intCast(sums.sumVisibleAdjacency(graph, adjacency, .rev));
            const pub_rev: u22 = meta.degree_rev;
            if (@as(usize, pub_rev) != live_rev) {
                try list.append(allocator, .{ .degree_mismatch = .{ .node = node_id, .expected = @intCast(live_rev), .actual = pub_rev } });
            }
            // RFC §6.3, §A.26: live predecessor with forward tombstone MUST
            // have needs_repair_fwd set.
            if (!adjacency.flags.needs_repair_fwd and v.forwardHasTombstone(graph, adjacency)) {
                try list.append(allocator, .{ .forward_tombstone_missing_repair_flag = .{ .node = node_id } });
            }
        }

        if (adjacency.flags.removed and (adjacency.block_count_fwd != 0 or adjacency.group_count_fwd != 0 or meta.degree_fwd != 0)) {
            try list.append(allocator, .{ .removed_node_has_outgoing = .{ .node = node_id } });
        }
        if (adjacency.flags.removed and meta.degree_rev != 0) {
            try list.append(allocator, .{ .removed_node_has_reverse_residual = .{ .node = node_id, .degree_rev = meta.degree_rev } });
        }
        if (adjacency.flags.removed and (adjacency.flags.needs_repair_fwd or adjacency.flags.needs_repair_rev)) {
            try list.append(allocator, .{ .removed_node_marked_for_repair = .{ .node = node_id } });
        }

        // RFC §3.2: at most MAX_GROUPS_PER_NODE runs without repair.
        // Removed nodes are exempt from layout debt checks: their reverse side
        // may retain grouped tombstones until compaction (RFC §6.3).
        if (!adjacency.flags.removed) {
            if (adjacency.group_count_fwd > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_fwd) {
                try list.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
            }
            if (adjacency.group_count_rev > constants.MAX_GROUPS_PER_NODE and !adjacency.flags.needs_repair_rev) {
                try list.append(allocator, .{ .occupancy_below_threshold = .{ .node = node_id, .block = 0, .occupancy = 0 } });
            }
            try consistency.appendLayoutDebtViolations(graph, allocator, &list, node_id, adjacency, .fwd);
            try consistency.appendLayoutDebtViolations(graph, allocator, &list, node_id, adjacency, .rev);
        }
    }

    try consistency.appendRepairDebtViolations(graph, allocator, &list);

    {
        const fwd_limit = @atomicLoad(u32, @constCast(&graph.block_fwd_count), .acquire);
        for (0..fwd_limit) |block_index| {
            if (!owned_forward_blocks.isSet(block_index) and
                !free_forward_blocks.isSet(block_index) and
                !retired_forward_blocks.isSet(block_index))
            {
                try list.append(allocator, .{ .unreachable_forward_block = .{ .block = @intCast(block_index) } });
            }
        }
    }
    {
        const rev_limit = @atomicLoad(u32, @constCast(&graph.block_rev_count), .acquire);
        for (0..rev_limit) |block_index| {
            if (!owned_reverse_blocks.isSet(block_index) and
                !free_reverse_blocks.isSet(block_index) and
                !retired_reverse_blocks.isSet(block_index))
            {
                try list.append(allocator, .{ .unreachable_reverse_block = .{ .block = @intCast(block_index) } });
            }
        }
    }
    {
        for (0..group_limit) |group_index| {
            if (!owned_groups_debug.isSet(group_index) and
                !free_groups_debug.isSet(group_index) and
                !retired_groups_debug.isSet(group_index))
            {
                try list.append(allocator, .{ .unreachable_group = .{ .group = @intCast(group_index) } });
            }
        }
    }

    if (total_visible_fwd != total_visible_rev) {
        try list.append(allocator, .{ .forward_reverse_count_mismatch = .{ .forward_total = total_visible_fwd, .reverse_total = total_visible_rev } });
    }
    if (total_visible_fwd != graph.edge_count.load(.acquire)) {
        try list.append(allocator, .{ .edge_count_mismatch = .{ .expected = total_visible_fwd, .actual = graph.edge_count.load(.acquire) } });
    }

    return list.toOwnedSlice(allocator);
}
