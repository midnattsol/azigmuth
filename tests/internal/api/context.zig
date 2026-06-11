//! Coverage for the algorithm Context cancellation token primitives.
//! End-to-end cancellation of bfs/dfs/hasCycle is covered by the public
//! tests in tests/public/algorithms/cancellation.zig.

const std = @import("std");
const graph_mod = @import("graph_mod");
const context_mod = graph_mod.algorithms_context_mod;

const testing = std.testing;

test "CancelToken: starts clear, cancel is sticky and visible" {
    var token = context_mod.CancelToken.init();
    try testing.expect(!token.isCancelled());

    token.cancel();
    try testing.expect(token.isCancelled());

    // Cancelling again keeps it cancelled.
    token.cancel();
    try testing.expect(token.isCancelled());
}

test "Context: init defaults carry no cancel token until one is attached" {
    var ctx = context_mod.Context.init(testing.allocator);
    try testing.expectEqual(@as(?*context_mod.CancelToken, null), ctx.cancel_token);

    var token = context_mod.CancelToken.init();
    ctx.cancel_token = &token;
    try testing.expect(!ctx.cancel_token.?.isCancelled());
    token.cancel();
    try testing.expect(ctx.cancel_token.?.isCancelled());
}
