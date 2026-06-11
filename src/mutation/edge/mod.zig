//! Edge mutation facade.

const add = @import("add.zig");
const add_batch = @import("add_batch.zig");
const remove = @import("remove.zig");

pub const addEdge = add.addEdge;
pub const addEdgeWithId = add.addEdgeWithId;
pub const addEdges = add_batch.addEdges;
pub const removeEdge = remove.removeEdge;
pub const removeEdgeWithId = remove.removeEdgeWithId;
