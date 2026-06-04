const graph_mod = @import("graph_mod");

pub fn addNodes(graph: *graph_mod.Graph, comptime node_count: usize) ![node_count]graph_mod.NodeId {
    var nodes: [node_count]graph_mod.NodeId = undefined;
    for (0..node_count) |node_index| {
        nodes[node_index] = try graph.addNode();
    }
    return nodes;
}
