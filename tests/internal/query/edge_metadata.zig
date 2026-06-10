const std = @import("std");
const graph_mod = @import("graph_mod");
const publish = @import("publish");
const testing = std.testing;

test "edge metadata: distinct relation values coexist in the same forward adjacency" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [5]graph_mod.NodeId = undefined;
    for (0..targets.len) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], @intCast(target_index), 0);
    }

    const adj = try graph.publishedNodeAdj(source);
    var seen_relations: [5]bool = .{ false } ** 5;
    const live = try publish.forwardLiveCount(&graph, adj);
    for (0..live) |entry_idx| {
        const relation: usize = (try publish.readForwardEntry(&graph, adj, entry_idx)).relation;
        try testing.expect(relation < 5);
        try testing.expect(!seen_relations[relation]);
        seen_relations[relation] = true;
    }
    for (seen_relations) |saw| try testing.expect(saw);

    try graph.validate();
}

test "edge metadata: edge presence is preserved when only a subset is removed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const peer_count: usize = 6;
    var peers: [peer_count]graph_mod.NodeId = undefined;
    for (0..peer_count) |peer_index| {
        peers[peer_index] = try graph.addNode();
        try graph.addEdge(source, peers[peer_index], @intCast(peer_index + 1), 0);
    }

    try testing.expect(try graph.removeEdge(source, peers[2]));
    try testing.expect(try graph.removeEdge(source, peers[4]));

    const adj = try graph.publishedNodeAdj(source);
    const live = try publish.forwardLiveCount(&graph, adj);
    try testing.expectEqual(@as(u64, peer_count - 2), live);

    // Verify each surviving edge carries the correct destination→relation pair.
    var expected_relation_by_dest: [peer_count]?u16 = [_]?u16{null} ** peer_count;
    for (0..peer_count) |peer_index| {
        if (peer_index == 2 or peer_index == 4) continue;
        expected_relation_by_dest[peer_index] = @intCast(peer_index + 1);
    }

    var seen_count: usize = 0;
    for (0..@intCast(live)) |entry_idx| {
        const entry = try publish.readForwardEntry(&graph, adj, entry_idx);
        const dest_index: u32 = entry.destination;
        const relation: u16 = entry.relation;
        var matched = false;
        for (peers, 0..) |peer, peer_index| {
            if (peer.index == dest_index) {
                try testing.expect(expected_relation_by_dest[peer_index] != null);
                try testing.expectEqual(expected_relation_by_dest[peer_index].?, relation);
                expected_relation_by_dest[peer_index] = null;
                matched = true;
                seen_count += 1;
                break;
            }
        }
        try testing.expect(matched);
    }
    try testing.expectEqual(@as(usize, peer_count - 2), seen_count);

    try graph.validate();
}

test "edge metadata: non-zero flags survive a chain of mutations that force copy-on-write" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 6;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], 0, @bitCast(@as(u16, 0xDEAD)));
    }

    const flags_keep: u16 = @bitCast(@as(u16, 0xBEEF));
    var extra_nodes: [3]graph_mod.NodeId = undefined;
    for (0..3) |extra_idx| {
        extra_nodes[extra_idx] = try graph.addNode();
        try graph.addEdge(source, extra_nodes[extra_idx], 0, 0);
    }
    _ = try graph.removeEdge(source, targets[0]);
    _ = try graph.removeEdge(source, targets[1]);
    const replacement = try graph.addNode();
    try graph.addEdge(source, replacement, 0, flags_keep);

    // Build expected (destination, flags) pairs.
    var expected = std.AutoHashMap(u32, u16).init(testing.allocator);
    defer expected.deinit();
    for (2..target_count) |idx| {
        try expected.put(targets[idx].index, @bitCast(@as(u16, 0xDEAD)));
    }
    for (extra_nodes) |extra| {
        try expected.put(extra.index, 0);
    }
    try expected.put(replacement.index, flags_keep);

    const adj = try graph.publishedNodeAdj(source);
    const live = try publish.forwardLiveCount(&graph, adj);
    try testing.expectEqual(@as(u64, expected.count()), live);

    for (0..@intCast(live)) |entry_idx| {
        const entry = try publish.readForwardEntry(&graph, adj, entry_idx);
        const dest = entry.destination;
        const raw_flags = @as(u16, @bitCast(entry.flags));
        const expected_flags = expected.get(dest) orelse {
            try testing.expect(false); // destination not in expected set
            unreachable;
        };
        try testing.expectEqual(expected_flags, raw_flags);
        _ = expected.remove(dest); // mark matched
    }
    try testing.expectEqual(@as(u32, 0), expected.count());

    try graph.validate();
}

test "edge metadata: forward adjacency still finds specific destination after a repair storm" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: usize = 70;
    var targets: [target_count]graph_mod.NodeId = undefined;
    for (0..target_count) |target_index| {
        targets[target_index] = try graph.addNode();
        try graph.addEdge(source, targets[target_index], @intCast(target_index % 4), 0);
    }

    const remove_indices = [_]usize{ 69, 68, 67, 66, 65 };
    for (remove_indices) |idx| {
        _ = try graph.removeEdge(source, targets[idx]);
    }
    try graph.repairNode(source);

    const snapshot = try graph.publishedNodeAdj(source);
    for (0..target_count) |idx| {
        const present = graph.hasEdgeInAdj(snapshot, targets[idx].index);
        var is_removed = false;
        for (remove_indices) |removed| {
            if (removed == idx) is_removed = true;
        }
        if (is_removed) {
            try testing.expect(!present);
        } else {
            try testing.expect(present);
        }
    }
    try graph.validate();
}

test "edge metadata: relation = u16 max and flags with all bits set round-trip" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();

    try graph.addEdge(source, target, std.math.maxInt(u16), std.math.maxInt(u16));
    try graph.validate();

    const adj = try graph.publishedNodeAdj(source);
    const entry = try publish.readForwardEntry(&graph, adj, 0);
    try testing.expectEqual(std.math.maxInt(u16), entry.relation);
    try testing.expectEqual(std.math.maxInt(u16), @as(u16, @bitCast(entry.flags)));

    try testing.expect(graph.hasEdgeInAdj(adj, target.index));
}

test "edge metadata: relation = 0 and flags = 0 round-trip correctly" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target = try graph.addNode();

    try graph.addEdge(source, target, 0, 0);
    try graph.validate();

    const adj = try graph.publishedNodeAdj(source);
    const entry = try publish.readForwardEntry(&graph, adj, 0);
    try testing.expectEqual(@as(u16, 0), entry.relation);
    try testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(entry.flags)));
}
