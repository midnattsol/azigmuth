const std = @import("std");
const graphz = @import("graphz");

pub fn outDegree(graph: *graphz.Graph, node: graphz.NodeId, allocator: std.mem.Allocator) !usize { var snapshot = try graph.snapshot(allocator); defer snapshot.deinit(); return snapshot.outDegree(node); }
