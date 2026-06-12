//! Node pool pages: NodeMeta, NodePublished and NodeHot accessors over the
//! node page directories.

const std = @import("std");
const constants = @import("../../core/constants.zig");
const graph_core = @import("../../core/graph_core.zig");
const types = @import("../../core/types.zig");
const node_meta = @import("../node/meta.zig");
const node_hot = @import("../node/hot.zig");
const node_hot_layout = @import("../node/hot_layout.zig");
const node_published = @import("../node/published.zig");
const common = @import("common.zig");

pub fn nodeMetaAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_meta.NodeMeta {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_meta.NodeMeta, &graph.node_meta_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeMetaPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_meta.NodeMeta {
    return common.ensurePage(graph, node_meta.NodeMeta, &graph.node_meta_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn nodeMetaAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_meta.NodeMeta {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPage(node_meta.NodeMeta, &graph.node_meta_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodePublishedPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_published.NodePublished {
    return common.ensurePage(graph, node_published.NodePublished, &graph.node_published_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn ensureNodePublishedAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_published.NodePublished {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodePublishedPage(graph, page_idx);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodePublishedAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_published.NodePublished {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_published.NodePublished, &graph.node_published_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn nodePublishedAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_published.NodePublished {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const raw = graph.node_published_pages.load(page_idx);
    std.debug.assert(raw != 0);
    const page = common.loadPage(node_published.NodePublished, &graph.node_published_pages, page_idx, constants.NODES_PER_PAGE);
    return &page[common.slotOf(id.index, constants.NODES_PER_PAGE)];
}

pub fn ensureNodeHotPage(graph: *graph_core.GraphCore, page_idx: u32) ![]node_hot_layout.Slot {
    return common.ensurePage(graph, node_hot_layout.Slot, &graph.node_hot_pages, page_idx, constants.NODES_PER_PAGE);
}

pub fn ensureNodeHotAt(graph: *graph_core.GraphCore, id: types.NodeId) !*node_hot.NodeHot {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = try ensureNodeHotPage(graph, page_idx);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeHotAt(graph: *graph_core.GraphCore, id: types.NodeId) *node_hot.NodeHot {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPageMut(node_hot_layout.Slot, &graph.node_hot_pages, page_idx, constants.NODES_PER_PAGE);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].node();
}

pub fn nodeHotAtConst(graph: *const graph_core.GraphCore, id: types.NodeId) *const node_hot.NodeHot {
    const page_idx = common.pageOf(id.index, constants.NODES_PER_PAGE);
    const page = common.loadPage(node_hot_layout.Slot, &graph.node_hot_pages, page_idx, constants.NODES_PER_PAGE);
    return page[common.slotOf(id.index, constants.NODES_PER_PAGE)].nodeConst();
}

/// Returns one node-meta page as a read-only slice.
pub fn nodeMetaPageAtConst(graph: *const graph_core.GraphCore, page_idx: u32) []const node_meta.NodeMeta {
    return common.loadPage(node_meta.NodeMeta, &graph.node_meta_pages, page_idx, constants.NODES_PER_PAGE);
}

/// Returns one published-descriptor page, or null when the page was never
/// allocated (every node in it has provably empty published sides).
pub fn nodePublishedPageAtConst(graph: *const graph_core.GraphCore, page_idx: u32) ?[]const node_published.NodePublished {
    const raw = graph.node_published_pages.load(page_idx);
    if (raw == 0) return null;
    return common.ptrFromRawConst(node_published.NodePublished, raw, constants.NODES_PER_PAGE);
}
