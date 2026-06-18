const std = @import("std");
const graph_mod = @import("graph_mod");
const constants = graph_mod.constants_mod;
const page_ops = graph_mod.page_ops_mod;
const types = graph_mod.types_mod;

const Graph = graph_mod.Graph;
const testing = std.testing;

test "graph structure: multiple blocks trigger segment creation and still iterate" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: u32 = 130;
    var targets: [130]types.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();

    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(source));

    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqual(@as(usize, target_count), slice.len);
    for (1..slice.len) |target_idx| {
        try testing.expect(slice[target_idx - 1].index < slice[target_idx].index);
    }
}

test "graph structure: removeEdge from multi-block node decreases degree" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: u32 = 65;
    var targets: [65]types.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(source));
    try testing.expect(try graph.removeEdge(source, targets[target_count - 1]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 1), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, target_count - 1), graph.edgeCount());
    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 1), slice.len);
}

test "graph structure: removeEdge from first block in multi-block node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: u32 = 65;
    var targets: [65]types.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count), try graph.outDegree(source));
    try testing.expect(try graph.removeEdge(source, targets[0]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 1), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, target_count - 1), graph.edgeCount());
    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 1), slice.len);
    try testing.expectEqual(targets[1].index, slice[0].index);
}

test "graph structure: removeEdge multiple edges from multi-block node" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const target_count: u32 = 70;
    var targets: [70]types.NodeId = undefined;
    for (0..target_count) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();
    try testing.expect(try graph.removeEdge(source, targets[0]));
    try graph.validate();
    try testing.expect(try graph.removeEdge(source, targets[34]));
    try graph.validate();
    try testing.expect(try graph.removeEdge(source, targets[69]));
    try graph.validate();
    try testing.expectEqual(@as(usize, target_count - 3), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, target_count - 3), graph.edgeCount());
    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, target_count - 3), slice.len);
    for (1..slice.len) |target_idx| {
        try testing.expect(slice[target_idx - 1].index < slice[target_idx].index);
    }
}

test "graph structure: removeEdge preserves unrelated incoming and outgoing adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const destination = try graph.addNode();
    const other_destination = try graph.addNode();
    const incoming_source = try graph.addNode();
    const downstream = try graph.addNode();

    try graph.addEdge(source, destination, 0, 0);
    try graph.addEdge(source, other_destination, 0, 0);
    try graph.addEdge(incoming_source, source, 0, 0);
    try graph.addEdge(destination, downstream, 0, 0);

    try graph.validate();
    try testing.expect(try graph.removeEdge(source, destination));
    try graph.validate();

    try testing.expectEqual(@as(usize, 1), try graph.outDegree(source));
    var source_neighbors_it = try graph.neighbors(source);
    defer source_neighbors_it.deinit();
    const source_neighbors = try graph_mod.materializeConsuming(&source_neighbors_it, testing.allocator);
    defer testing.allocator.free(source_neighbors);
    try testing.expectEqual(other_destination.index, source_neighbors[0].index);

    try testing.expectEqual(@as(usize, 1), try graph.inDegree(source));
    var source_incoming_it = try graph.inNeighbors(source);
    defer source_incoming_it.deinit();
    const source_incoming = try graph_mod.materializeConsuming(&source_incoming_it, testing.allocator);
    defer testing.allocator.free(source_incoming);
    try testing.expectEqual(incoming_source.index, source_incoming[0].index);

    try testing.expectEqual(@as(usize, 1), try graph.outDegree(destination));
    var destination_neighbors_it = try graph.neighbors(destination);
    defer destination_neighbors_it.deinit();
    const destination_neighbors = try graph_mod.materializeConsuming(&destination_neighbors_it, testing.allocator);
    defer testing.allocator.free(destination_neighbors);
    try testing.expectEqual(downstream.index, destination_neighbors[0].index);

    try testing.expectEqual(@as(usize, 0), try graph.inDegree(destination));
    try testing.expectEqual(@as(u64, 3), graph.edgeCount());
}

test "graph structure: removeEdge preserves destination forward adjacency and remaining reverse entries" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const removed_source = try graph.addNode();
    const stable_source = try graph.addNode();
    const destination = try graph.addNode();
    const stable_destination_one = try graph.addNode();
    const stable_destination_two = try graph.addNode();

    try graph.addEdge(stable_source, stable_destination_one, 0, 0);
    try graph.addEdge(stable_source, stable_destination_two, 0, 0);
    try graph.addEdge(removed_source, destination, 0, 0);
    try graph.addEdge(stable_destination_one, destination, 0, 0);

    try graph.validate();
    try testing.expect(try graph.removeEdge(removed_source, destination));
    try graph.validate();

    try testing.expectEqual(@as(usize, 2), try graph.outDegree(stable_source));
    var stable_neighbors_it = try graph.neighbors(stable_source);
    defer stable_neighbors_it.deinit();
    const stable_neighbors = try graph_mod.materializeConsuming(&stable_neighbors_it, testing.allocator);
    defer testing.allocator.free(stable_neighbors);
    try testing.expectEqual(@as(usize, 2), stable_neighbors.len);

    try testing.expectEqual(@as(usize, 1), try graph.inDegree(destination));
    var destination_incoming_it = try graph.inNeighbors(destination);
    defer destination_incoming_it.deinit();
    const destination_incoming = try graph_mod.materializeConsuming(&destination_incoming_it, testing.allocator);
    defer testing.allocator.free(destination_incoming);
    try testing.expectEqual(stable_destination_one.index, destination_incoming[0].index);
}

test "graph structure: removeEdge preserves self-edge and unrelated incoming edge" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const removed_destination = try graph.addNode();
    const incoming_source = try graph.addNode();

    try graph.addEdge(node, node, 0, 0);
    try graph.addEdge(node, removed_destination, 0, 0);
    try graph.addEdge(incoming_source, node, 0, 0);

    try graph.validate();
    try testing.expect(try graph.removeEdge(node, removed_destination));
    try graph.validate();

    try testing.expectEqual(@as(usize, 1), try graph.outDegree(node));
    try testing.expectEqual(@as(usize, 2), try graph.inDegree(node));

    var it_node = try graph.neighbors(node);
    defer it_node.deinit();
    const fwd_node = try graph_mod.materializeConsuming(&it_node, testing.allocator);
    defer testing.allocator.free(fwd_node);
    try testing.expectEqual(node.index, fwd_node[0].index);

    var it_node_rev = try graph.inNeighbors(node);
    defer it_node_rev.deinit();
    const rev_node = try graph_mod.materializeConsuming(&it_node_rev, testing.allocator);
    defer testing.allocator.free(rev_node);
    try testing.expectEqual(@as(usize, 2), rev_node.len);
    try testing.expectEqual(node.index, rev_node[0].index);
    try testing.expectEqual(incoming_source.index, rev_node[1].index);
}

test "graph structure: non-tail simple remove completes and stays consistent" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [65]types.NodeId = undefined;
    for (0..65) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 65), try graph.outDegree(source));

    try testing.expect(try graph.removeEdge(source, targets[0]));
    try graph.validate();
    try testing.expectEqual(@as(usize, 64), try graph.outDegree(source));
    try testing.expectEqual(@as(u64, 64), graph.edgeCount());
}

test "graph structure: copy-on-write tail replacement preserves segmented adjacency" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [70]types.NodeId = undefined;
    for (0..70) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 70), try graph.outDegree(source));

    _ = try graph.removeEdge(source, targets[69]);
    try graph.validate();

    const new_target = try graph.addNode();
    try graph.addEdge(source, new_target, 0, 0);
    try graph.validate();

    try testing.expectEqual(@as(usize, 70), try graph.outDegree(source));
    var iterator = try graph.neighbors(source);
    defer iterator.deinit();
    const slice = try graph_mod.materializeConsuming(&iterator, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqual(@as(usize, 70), slice.len);

    for (0..69) |target_idx| {
        if (targets[target_idx].index != targets[69].index) {
            try testing.expectEqual(@as(usize, 1), try graph.inDegree(targets[target_idx]));
        }
    }

    for (0..30) |_| {
        const target = try graph.addNode();
        try graph.addEdge(source, target, 0, 0);
    }
    try graph.validate();
    try testing.expectEqual(@as(usize, 100), try graph.outDegree(source));
}

test "graph structure: non-tail removal allocates only bounded fresh blocks" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [65]types.NodeId = undefined;
    for (0..65) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, 0);
    }

    const fwd_blocks_before = graph.graph.block_fwd_count;

    try testing.expect(try graph.removeEdge(source, targets[0]));

    // The structural rebuild shares unchanged blocks: a single removal may
    // COW the affected block but never clones the whole side.
    try testing.expect(graph.graph.block_fwd_count <= fwd_blocks_before + 2);
    try graph.validate();
}

test "graph structure: reused free block starts empty" {
    var graph = try Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    const removed_destination = try graph.addNode();
    try graph.addEdge(source, removed_destination, 0, 0);
    try testing.expect(try graph.removeEdge(source, removed_destination));

    graph.bumpEpoch();
    graph.bumpEpoch();
    graph.reclaimRetired();
    const recycled_source = try graph.addNode();
    const destination = try graph.addNode();
    try graph.addEdge(recycled_source, destination, 0, 0);
    try graph.validate();
    try testing.expectEqual(@as(usize, 1), try graph.outDegree(recycled_source));
    try testing.expectEqual(@as(u64, 1), graph.edgeCount());
}
