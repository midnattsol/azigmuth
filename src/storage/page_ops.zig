//! Page-based indexed access and allocation for graph storage — the facade.
//! One import point for every storage pool; the implementations live in
//! `pages/`, split by responsibility:
//!
//!   - `common`    — page arithmetic and lazy page publication
//!   - `index_stack` — intrusive tagged-head stacks for recycled indices
//!   - `nodes`     — NodePublicationCell / NodeAdjacencyBuffers / NodeMutationControl pages
//!   - `tiny`      — tiny slots and their free/retired stacks
//!   - `prop_rows` — property-row lifecycle (edge_properties mode)
//!   - `blocks`    — edge blocks, sidecars, live counts, span allocation,
//!     frontier rollback
//!   - `segments`    — edge-block segment descriptors and per-span-length stacks
//!
//! Every symbol below re-exports flat so call sites keep reading
//! `page_ops.<fn>` regardless of which pool owns it.

const common = @import("pages/common.zig");
const index_stack = @import("pages/index_stack.zig");
const nodes = @import("pages/nodes.zig");
const tiny = @import("pages/tiny.zig");
const prop_rows = @import("pages/prop_rows.zig");
const blocks = @import("pages/blocks.zig");
const segments = @import("pages/segments.zig");

// ── common ───────────────────────────────────────────────────────────
pub const pageOf = common.pageOf;
pub const slotOf = common.slotOf;
pub const makeIndex = common.makeIndex;

// ── index stacks ─────────────────────────────────────────────────────
pub const EMPTY_INDEX = index_stack.EMPTY_INDEX;
pub const StackKind = index_stack.StackKind;
pub const LockFreeIndexStack = index_stack.LockFreeIndexStack;
pub const stackHeadIndex = index_stack.headIndex;
pub const reclamationNext = index_stack.reclamationNext;
pub const walkDetachedIndexStack = index_stack.walkDetached;

// ── nodes ────────────────────────────────────────────────────────────
pub const nodePublicationAt = nodes.nodePublicationAt;
pub const ensureNodePublicationPage = nodes.ensureNodePublicationPage;
pub const nodePublicationAtConst = nodes.nodePublicationAtConst;
pub const ensureNodeAdjacencyBufferPage = nodes.ensureNodeAdjacencyBufferPage;
pub const ensureNodeAdjacencyBuffersAt = nodes.ensureNodeAdjacencyBuffersAt;
pub const nodeAdjacencyBuffersAt = nodes.nodeAdjacencyBuffersAt;
pub const nodeAdjacencyBuffersAtConst = nodes.nodeAdjacencyBuffersAtConst;
pub const ensureNodeMutationControlPage = nodes.ensureNodeMutationControlPage;
pub const ensureNodeMutationControlAt = nodes.ensureNodeMutationControlAt;
pub const nodeMutationControlAt = nodes.nodeMutationControlAt;
pub const nodeMutationControlAtConst = nodes.nodeMutationControlAtConst;
pub const nodePublicationPageAtConst = nodes.nodePublicationPageAtConst;
pub const nodeAdjacencyBufferPageAtConst = nodes.nodeAdjacencyBufferPageAtConst;

// ── tiny blocks ──────────────────────────────────────────────────────
pub const freeTinySlot = tiny.freeTinySlot;
pub const retireTinySlot = tiny.retireTinySlot;
pub const reclaimRetiredTinySlots = tiny.reclaimRetiredTinySlots;
pub const tinySlotAt = tiny.tinySlotAt;
pub const tinySlotAtConst = tiny.tinySlotAtConst;
pub const allocTinySlot = tiny.allocTinySlot;
pub const allocTinySlotRaw = tiny.allocTinySlotRaw;
pub const ensureTinyCapacity = tiny.ensureTinyCapacity;

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

// ── segmented segments ─────────────────────────────────────────────────────
pub const edgeBlockSegmentAt = segments.edgeBlockSegmentAt;
pub const edgeBlockSegmentAtConst = segments.edgeBlockSegmentAtConst;
pub const ensureSegmentCapacity = segments.ensureSegmentCapacity;
pub const allocSegmentSlots = segments.allocSegmentSlots;
pub const allocSegment = segments.allocSegment;
pub const freeSegmentSlots = segments.freeSegmentSlots;
pub const freeSegment = segments.freeSegment;
pub const retireSegmentSlots = segments.retireSegmentSlots;
pub const retireSegment = segments.retireSegment;
pub const reclaimRetiredSegments = segments.reclaimRetiredSegments;
