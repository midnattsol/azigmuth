const std = @import("std");
const harness = @import("harness.zig");
const read_cases = @import("cases/read.zig");
const mutation_cases = @import("cases/mutation.zig");
const maintenance_cases = @import("cases/maintenance.zig");
const algorithm_cases = @import("cases/algorithms.zig");

const all_cases = read_cases.cases ++ mutation_cases.cases ++ maintenance_cases.cases ++ algorithm_cases.cases;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const options = harness.parseOptions(init) catch |err| switch (err) {
        error.InvalidArguments => {
            std.debug.print(
                "usage: zig build bench -- [--list] [--filter SUBSTR] [--reps N] [--warmup N]\n",
                .{},
            );
            return err;
        },
        else => return err,
    };

    if (options.list) {
        harness.listCases(&all_cases);
        return;
    }

    std.debug.print(
        "graphz bench v2 (ReleaseFast recommended) reps={} warmup={}\n\n",
        .{ options.reps, options.warmup },
    );

    var ran_any = false;
    for (all_cases) |case_def| {
        if (!harness.matchesFilter(options, case_def.name)) continue;
        const summary = try harness.runCase(allocator, case_def, options);
        harness.printSummary(summary);
        ran_any = true;
    }

    if (!ran_any) {
        std.debug.print("no benchmark matched filter\n", .{});
    }
}
