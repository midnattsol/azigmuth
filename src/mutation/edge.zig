//! Edge mutation facade.

const add = @import("edge_add.zig");
const remove = @import("edge_remove.zig");

pub const addEdge = add.addEdge;
pub const addEdgeWithId = add.addEdgeWithId;
pub const removeEdge = remove.removeEdge;
pub const removeEdgeWithId = remove.removeEdgeWithId;
