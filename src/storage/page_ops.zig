//! Page-based indexed access and allocation for graph storage — the facade.
//! One import point for every storage pool; the implementations live in
//! `pages/`, split by responsibility:
//!
//!   - `common`    — page arithmetic, lazy page publication, tagged-stack helpers
//!   - `nodes`     — NodeMeta / NodePublished / NodeHot pages
//!   - `tiny`      — tiny slots and their free/retired stacks
//!   - `prop_rows` — property-row lifecycle (edge_properties mode)
//!   - `blocks`    — edge blocks, sidecars, live counts, span allocation,
//!     frontier rollback
//!   - `groups`    — grouped-run descriptors and per-span-length stacks
//!
//! Every symbol below re-exports flat so call sites keep reading
//! `page_ops.<fn>` regardless of which pool owns it.

const common = @import("pages/common.zig");
const nodes = @import("pages/nodes.zig");
const tiny = @import("pages/tiny.zig");
const prop_rows = @import("pages/prop_rows.zig");
const blocks = @import("pages/blocks.zig");
const groups = @import("pages/groups.zig");

// ── common ───────────────────────────────────────────────────────────
pub const pageOf = common.pageOf;
pub const slotOf = common.slotOf;
pub const makeIndex = common.makeIndex;

// ── nodes ────────────────────────────────────────────────────────────
pub const nodeMetaAt = nodes.nodeMetaAt;
pub const ensureNodeMetaPage = nodes.ensureNodeMetaPage;
pub const nodeMetaAtConst = nodes.nodeMetaAtConst;
pub const ensureNodePublishedPage = nodes.ensureNodePublishedPage;
pub const ensureNodePublishedAt = nodes.ensureNodePublishedAt;
pub const nodePublishedAt = nodes.nodePublishedAt;
pub const nodePublishedAtConst = nodes.nodePublishedAtConst;
pub const ensureNodeHotPage = nodes.ensureNodeHotPage;
pub const ensureNodeHotAt = nodes.ensureNodeHotAt;
pub const nodeHotAt = nodes.nodeHotAt;
pub const nodeHotAtConst = nodes.nodeHotAtConst;
pub const nodeMetaPageAtConst = nodes.nodeMetaPageAtConst;
pub const nodePublishedPageAtConst = nodes.nodePublishedPageAtConst;

// ── tiny blocks ──────────────────────────────────────────────────────
pub const freeTinySlot = tiny.freeTinySlot;
pub const retireTinyBlock = tiny.retireTinyBlock;
pub const reclaimRetiredTinyBlocks = tiny.reclaimRetiredTinyBlocks;
pub const tinyBlockAt = tiny.tinyBlockAt;
pub const tinyBlockAtConst = tiny.tinyBlockAtConst;
pub const allocTinyBlock = tiny.allocTinyBlock;
pub const allocTinyBlockRaw = tiny.allocTinyBlockRaw;

// ── property rows ────────────────────────────────────────────────────
pub const freePropRow = prop_rows.freePropRow;
pub const retirePropRow = prop_rows.retirePropRow;
pub const reclaimRetiredPropRows = prop_rows.reclaimRetiredPropRows;
pub const ensurePropRowCapacity = prop_rows.ensurePropRowCapacity;
pub const allocPropRow = prop_rows.allocPropRow;

// ── edge blocks ──────────────────────────────────────────────────────
pub const edgeBlockPageRaw = blocks.edgeBlockPageRaw;
pub const blockAlivePageRaw = blocks.blockAlivePageRaw;
pub const edgeBlockFwdIdsPageRaw = blocks.edgeBlockFwdIdsPageRaw;
pub const edgeBlockFwdPropsPageRaw = blocks.edgeBlockFwdPropsPageRaw;
pub const edgeBlockFwdAt = blocks.edgeBlockFwdAt;
pub const edgeBlockFwdAtConst = blocks.edgeBlockFwdAtConst;
pub const edgeBlockFwdIdsAt = blocks.edgeBlockFwdIdsAt;
pub const edgeBlockFwdIdsAtConst = blocks.edgeBlockFwdIdsAtConst;
pub const edgeBlockFwdPropsAt = blocks.edgeBlockFwdPropsAt;
pub const edgeBlockFwdPropsAtConst = blocks.edgeBlockFwdPropsAtConst;
pub const edgeBlockRevAt = blocks.edgeBlockRevAt;
pub const edgeBlockRevAtConst = blocks.edgeBlockRevAtConst;
pub const edgeBlockAt = blocks.edgeBlockAt;
pub const edgeBlockAtConst = blocks.edgeBlockAtConst;
pub const blockAliveCountPtr = blocks.blockAliveCountPtr;
pub const blockAliveCount = blocks.blockAliveCount;
pub const setBlockAliveCount = blocks.setBlockAliveCount;
pub const allocFreshBlockSpan = blocks.allocFreshBlockSpan;
pub const allocFreshBlockSpanRaw = blocks.allocFreshBlockSpanRaw;
pub const ensureBlockCapacity = blocks.ensureBlockCapacity;
pub const allocBlock = blocks.allocBlock;
pub const freeBlock = blocks.freeBlock;
pub const retireBlock = blocks.retireBlock;
pub const reclaimRetired = blocks.reclaimRetired;

// ── grouped runs ─────────────────────────────────────────────────────
pub const edgeBlockGroupAt = groups.edgeBlockGroupAt;
pub const edgeBlockGroupAtConst = groups.edgeBlockGroupAtConst;
pub const allocGroupSpan = groups.allocGroupSpan;
pub const allocGroup = groups.allocGroup;
pub const freeGroupSpan = groups.freeGroupSpan;
pub const freeGroup = groups.freeGroup;
pub const retireGroupSpan = groups.retireGroupSpan;
pub const retireGroup = groups.retireGroup;
pub const reclaimRetiredGroups = groups.reclaimRetiredGroups;
