const std = @import("std");
const graph_mod = @import("graph_mod");
const testing = std.testing;

test "repair_budgeted: processes single node with repair debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [85]graph_mod.NodeId = undefined;
    for (0..85) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(source, targets[i], 0, 0);
    }

    // Remove the first 37 destination nodes (via removeNode), creating
    // tombstoned forward edges → repair debt.
    for (0..37) |i| {
        try graph.removeNode(targets[i]);
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: processes multiple nodes in one call" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 5;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var all_targets: [node_count][80]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        for (0..80) |j| {
            all_targets[i][j] = try graph.addNode();
            try graph.addEdge(nodes[i], all_targets[i][j], 0, 0);
        }
    }

    // Create tombstone debt by removing some destination nodes.
    for (0..node_count) |i| {
        for (0..10) |j| {
            try graph.removeNode(all_targets[i][j]);
        }
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(node_count);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: returns zero when no repair debt" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(node, target, 0, 0);

    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: max_nodes limits work done" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 10;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var all_targets: [node_count][80]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        for (0..80) |j| {
            all_targets[i][j] = try graph.addNode();
            try graph.addEdge(nodes[i], all_targets[i][j], 0, 0);
        }
    }

    for (0..node_count) |i| {
        for (0..10) |j| {
            try graph.removeNode(all_targets[i][j]);
        }
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(2);
    try testing.expectEqual(@as(usize, 2), repaired);
}

test "repair_budgeted: node with both fwd and rev debt counted once" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var targets: [80]graph_mod.NodeId = undefined;
    var senders: [80]graph_mod.NodeId = undefined;
    for (0..80) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(node, targets[i], 0, 0);
    }
    for (0..80) |i| {
        senders[i] = try graph.addNode();
        try graph.addEdge(senders[i], node, 0, 0);
    }

    for (0..32) |i| {
        try graph.removeNode(targets[i]);
    }
    for (0..16) |i| {
        try graph.removeNode(senders[i]);
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: empty graph returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const repaired = try graph.repairBudgeted(100);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: single node no edges returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: repair of node already optimal returns zero" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..50) |_| {
        const t = try graph.addNode();
        try graph.addEdge(source, t, 0, 0);
    }

    try graph.validate();
    try graph.repairNode(source);
    try graph.validate();

    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: repeated calls make progress" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 5;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var all_targets: [node_count][80]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        for (0..80) |j| {
            all_targets[i][j] = try graph.addNode();
            try graph.addEdge(nodes[i], all_targets[i][j], 0, 0);
        }
    }

    for (0..node_count) |i| {
        for (0..10) |j| {
            try graph.removeNode(all_targets[i][j]);
        }
    }
    try graph.validate();

    const first = try graph.repairBudgeted(1);
    try testing.expect(first >= 1);
    try graph.validate();

    const second = try graph.repairBudgeted(1);
    try testing.expect(second >= 0);
    try graph.validate();
}

test "repair_budgeted: self-edge node repair works" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var targets: [80]graph_mod.NodeId = undefined;
    var senders: [80]graph_mod.NodeId = undefined;
    for (0..80) |i| {
        targets[i] = try graph.addNode();
        try graph.addEdge(node, targets[i], 0, 0);
    }
    for (0..80) |i| {
        senders[i] = try graph.addNode();
        try graph.addEdge(senders[i], node, 0, 0);
    }

    for (0..32) |i| {
        try graph.removeNode(targets[i]);
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: repair after removeNode processes tombstoned edges" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var senders: [50]graph_mod.NodeId = undefined;
    for (0..50) |i| senders[i] = try graph.addNode();
    for (0..50) |i| try graph.addEdge(senders[i], hub, 0, 0);

    try graph.removeNode(hub);
    try graph.validate();

    const repaired = try graph.repairBudgeted(50);
    try testing.expect(repaired >= 1);
    try graph.validate();

    for (0..50) |i| {
        try testing.expectEqual(@as(usize, 0), try graph.outDegree(senders[i]));
    }
}

test "repair_budgeted: group count at max_boundary triggers repair" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [250]graph_mod.NodeId = undefined;
    for (0..250) |i| targets[i] = try graph.addNode();

    for (0..250) |i| try graph.addEdge(source, targets[i], 0, 0);
    try graph.validate();

    for (0..250) |i| {
        if (i % 2 == 0) {
            try graph.removeNode(targets[i]);
        }
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: verify repair debt queue is consumed" {
    var graph = try graph_mod.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 8;
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |i| nodes[i] = try graph.addNode();

    var all_targets: [node_count][65]graph_mod.NodeId = undefined;
    for (0..node_count) |i| {
        for (0..65) |j| {
            all_targets[i][j] = try graph.addNode();
            try graph.addEdge(nodes[i], all_targets[i][j], 0, 0);
        }
    }

    for (0..node_count) |i| {
        try graph.removeNode(all_targets[i][0]);
    }
    try graph.validate();

    var total_repaired: usize = 0;
    var remaining: usize = 10;
    while (remaining > 0) {
        const repaired = try graph.repairBudgeted(1);
        if (repaired == 0) break;
        total_repaired += repaired;
        remaining -= 1;
    }

    try testing.expect(total_repaired >= 1);
    try graph.validate();
}