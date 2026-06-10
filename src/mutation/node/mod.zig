//! Node mutation facade.

const add = @import("add.zig");
const remove = @import("remove.zig");

pub const addNode = add.addNode;
pub const removeNode = remove.removeNode;
