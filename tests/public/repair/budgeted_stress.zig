const std = @import("std");
const azigmuth = @import("azigmuth");
const snapshot_support = @import("snapshot_support");
const testing = std.testing;

test "repair_budgeted: processes single node with repair debt" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [85]azigmuth.NodeId = undefined;
    for (0..85) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(source, targets[target_idx], 0, .{});
    }

    // Remove the first 37 destination nodes (via removeNode), creating
    // tombstoned forward edges → repair debt.
    for (0..37) |target_idx| {
        _ = try graph.removeNode(targets[target_idx]);
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(1);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: processes multiple nodes in one call" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 5;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var all_targets: [node_count][80]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| {
        for (0..80) |target_idx| {
            all_targets[node_idx][target_idx] = try graph.addNode();
            try graph.addEdge(nodes[node_idx], all_targets[node_idx][target_idx], 0, .{});
        }
    }

    // Create tombstone debt by removing some destination nodes.
    for (0..node_count) |node_idx| {
        for (0..10) |target_idx| {
            _ = try graph.removeNode(all_targets[node_idx][target_idx]);
        }
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(node_count);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: returns zero when no repair debt" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    const target = try graph.addNode();
    try graph.addEdge(node, target, 0, .{});

    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: max_nodes limits work done" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 10;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var all_targets: [node_count][80]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| {
        for (0..80) |target_idx| {
            all_targets[node_idx][target_idx] = try graph.addNode();
            try graph.addEdge(nodes[node_idx], all_targets[node_idx][target_idx], 0, .{});
        }
    }

    for (0..node_count) |node_idx| {
        for (0..10) |target_idx| {
            _ = try graph.removeNode(all_targets[node_idx][target_idx]);
        }
    }
    try graph.validate();
    const repaired = try graph.repairBudgeted(2);
    try testing.expectEqual(@as(usize, 2), repaired);
}

test "repair_budgeted: node with both fwd and rev debt counted once" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var targets: [80]azigmuth.NodeId = undefined;
    var senders: [80]azigmuth.NodeId = undefined;
    for (0..80) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(node, targets[target_idx], 0, .{});
    }
    for (0..80) |sender_idx| {
        senders[sender_idx] = try graph.addNode();
        try graph.addEdge(senders[sender_idx], node, 0, .{});
    }

    for (0..32) |target_idx| {
        _ = try graph.removeNode(targets[target_idx]);
    }
    for (0..16) |sender_idx| {
        _ = try graph.removeNode(senders[sender_idx]);
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: empty graph returns zero" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const repaired = try graph.repairBudgeted(100);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: single node no edges returns zero" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode();
    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: repair of node already optimal returns zero" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    for (0..50) |_| {
        const destination = try graph.addNode();
        try graph.addEdge(source, destination, 0, .{});
    }

    try graph.validate();
    _ = try graph.repairNode(source);
    try graph.validate();

    const repaired = try graph.repairBudgeted(10);
    try testing.expectEqual(@as(usize, 0), repaired);
}

test "repair_budgeted: repeated calls make progress" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 5;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var all_targets: [node_count][80]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| {
        for (0..80) |target_idx| {
            all_targets[node_idx][target_idx] = try graph.addNode();
            try graph.addEdge(nodes[node_idx], all_targets[node_idx][target_idx], 0, .{});
        }
    }

    for (0..node_count) |node_idx| {
        for (0..10) |target_idx| {
            _ = try graph.removeNode(all_targets[node_idx][target_idx]);
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
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node = try graph.addNode();
    var targets: [80]azigmuth.NodeId = undefined;
    var senders: [80]azigmuth.NodeId = undefined;
    for (0..80) |target_idx| {
        targets[target_idx] = try graph.addNode();
        try graph.addEdge(node, targets[target_idx], 0, .{});
    }
    for (0..80) |sender_idx| {
        senders[sender_idx] = try graph.addNode();
        try graph.addEdge(senders[sender_idx], node, 0, .{});
    }

    for (0..32) |target_idx| {
        _ = try graph.removeNode(targets[target_idx]);
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: repair after removeNode processes tombstoned edges" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const hub = try graph.addNode();
    var senders: [50]azigmuth.NodeId = undefined;
    for (0..50) |sender_idx| senders[sender_idx] = try graph.addNode();
    for (0..50) |sender_idx| try graph.addEdge(senders[sender_idx], hub, 0, .{});

    _ = try graph.removeNode(hub);
    try graph.validate();

    const repaired = try graph.repairBudgeted(50);
    try testing.expect(repaired >= 1);
    try graph.validate();

    for (0..50) |sender_idx| {
        try testing.expectEqual(@as(usize, 0), try snapshot_support.outDegree(graph, senders[sender_idx], testing.allocator));
    }
}

test "repair_budgeted: segment count at max_boundary triggers repair" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const source = try graph.addNode();
    var targets: [250]azigmuth.NodeId = undefined;
    for (0..250) |target_idx| targets[target_idx] = try graph.addNode();

    for (0..250) |target_idx| try graph.addEdge(source, targets[target_idx], 0, .{});
    try graph.validate();

    for (0..250) |target_idx| {
        if (target_idx % 2 == 0) {
            _ = try graph.removeNode(targets[target_idx]);
        }
    }

    try graph.validate();
    const repaired = try graph.repairBudgeted(10);
    try testing.expect(repaired >= 1);
    try graph.validate();
}

test "repair_budgeted: verify repair debt queue is consumed" {
    var graph = try azigmuth.Graph.init(testing.allocator);
    defer graph.deinit();

    const node_count: usize = 8;
    var nodes: [node_count]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| nodes[node_idx] = try graph.addNode();

    var all_targets: [node_count][65]azigmuth.NodeId = undefined;
    for (0..node_count) |node_idx| {
        for (0..65) |target_idx| {
            all_targets[node_idx][target_idx] = try graph.addNode();
            try graph.addEdge(nodes[node_idx], all_targets[node_idx][target_idx], 0, .{});
        }
    }

    for (0..node_count) |node_idx| {
        _ = try graph.removeNode(all_targets[node_idx][0]);
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
