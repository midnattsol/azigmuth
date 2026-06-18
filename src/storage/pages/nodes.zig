//! Node pool pages: NodePublicationCell, NodeAdjacencyBuffers and NodeMutationControl accessors over the
//! node page directories.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const node_publication = @import("../node/publication.zig");
const node_mutation_control = @import("../node/mutation_control.zig");
const node_mutation_control_layout = @import("../node/mutation_control_layout.zig");
const node_adjacency_buffers = @import("../node/adjacency_buffers.zig");
const common = @import("common.zig");

pub fn nodePublicationAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_publication.NodePublicationCell {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_publication.NodePublicationCell, &graph.node_publication_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodePublicationPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_publication.NodePublicationCell {
    return common.ensurePage(graph, node_publication.NodePublicationCell, &graph.node_publication_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn nodePublicationAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_publication.NodePublicationCell {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPage(node_publication.NodePublicationCell, &graph.node_publication_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeAdjacencyBufferPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_adjacency_buffers.NodeAdjacencyBuffers {
    return common.ensurePage(graph, node_adjacency_buffers.NodeAdjacencyBuffers, &graph.node_adjacency_buffer_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn ensureNodeAdjacencyBuffersAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_adjacency_buffers.NodeAdjacencyBuffers {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodeAdjacencyBufferPage(graph, page_idx);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeAdjacencyBuffersAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_adjacency_buffers.NodeAdjacencyBuffers {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_adjacency_buffers.NodeAdjacencyBuffers, &graph.node_adjacency_buffer_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodeAdjacencyBuffersAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_adjacency_buffers.NodeAdjacencyBuffers {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const raw = graph.node_adjacency_buffer_pages.load(page_idx);
    std.debug.assert(raw != 0);
    const page = common.loadPage(node_adjacency_buffers.NodeAdjacencyBuffers, &graph.node_adjacency_buffer_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeMutationControlPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_mutation_control_layout.Slot {
    return common.ensurePage(graph, node_mutation_control_layout.Slot, &graph.node_mutation_control_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn ensureNodeMutationControlAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_mutation_control.NodeMutationControl {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodeMutationControlPage(graph, page_idx);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeMutationControlAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_mutation_control.NodeMutationControl {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_mutation_control_layout.Slot, &graph.node_mutation_control_pages, page_idx, constants.NODES_PER_PAGE);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeMutationControlAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_mutation_control.NodeMutationControl {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPage(node_mutation_control_layout.Slot, &graph.node_mutation_control_pages, page_idx, constants.NODES_PER_PAGE);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].nodeConst();
}

/// Returns one node-publication page as a read-only slice.
pub fn nodePublicationPageAtConst(graph: *const graph_core.GraphCore, page_idx: u32) []const node_publication.NodePublicationCell {
    return common.loadPage(node_publication.NodePublicationCell, &graph.node_publication_pages, page_idx, constants.NODES_PER_PAGE);
}

/// Returns one published-descriptor page, or null when the page was never
/// allocated (every node in it has provably empty published sides).
pub fn nodeAdjacencyBufferPageAtConst(graph: *const graph_core.GraphCore, page_idx: u32) ?[]const node_adjacency_buffers.NodeAdjacencyBuffers {
    const raw = graph.node_adjacency_buffer_pages.load(page_idx);
    if (raw == 0) return null;
    return common.ptrFromRawConst(node_adjacency_buffers.NodeAdjacencyBuffers, raw, constants.NODES_PER_PAGE);
}
