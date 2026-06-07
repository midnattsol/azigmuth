const std = @import("std");
const builtin = @import("builtin");

pub const Result = struct {
    ops: usize,
    elapsed_ns: u64,
};

pub const Case = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator) anyerror!Result,
};

pub const Options = struct {
    filter: ?[]const u8 = null,
    reps: usize = 3,
    warmup: usize = 1,
    list: bool = false,
};

pub const Summary = struct {
    name: []const u8,
    ops: usize,
    min_ns: u64,
    median_ns: u64,
    max_ns: u64,
};

pub fn nowNs() u64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            var tp: std.os.linux.timespec = undefined;
            switch (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &tp))) {
                .SUCCESS => break :blk @as(u64, @intCast(tp.sec)) * std.time.ns_per_s + @as(u64, @intCast(tp.nsec)),
                else => unreachable,
            }
        },
        else => @compileError("bench currently supports linux targets only"),
    };
}

fn sortAscending(values: []u64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        var j = i;
        while (j > 0 and values[j - 1] > values[j]) : (j -= 1) {
            std.mem.swap(u64, &values[j - 1], &values[j]);
        }
    }
}

pub fn parseOptions(init: std.process.Init) !Options {
    var options = Options{};
    var args = try init.minimal.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            options.list = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--filter")) {
            options.filter = args.next() orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reps")) {
            const raw = args.next() orelse return error.InvalidArguments;
            options.reps = try std.fmt.parseUnsigned(usize, raw, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--warmup")) {
            const raw = args.next() orelse return error.InvalidArguments;
            options.warmup = try std.fmt.parseUnsigned(usize, raw, 10);
            continue;
        }
        return error.InvalidArguments;
    }

    if (options.reps == 0) return error.InvalidArguments;
    return options;
}

pub fn matchesFilter(options: Options, case_name: []const u8) bool {
    if (options.filter) |filter| {
        return std.mem.indexOf(u8, case_name, filter) != null;
    }
    return true;
}

pub fn listCases(cases: []const Case) void {
    for (cases) |case_def| {
        std.debug.print("{s}\n", .{case_def.name});
    }
}

pub fn runCase(allocator: std.mem.Allocator, case_def: Case, options: Options) !Summary {
    var warmup_idx: usize = 0;
    while (warmup_idx < options.warmup) : (warmup_idx += 1) {
        _ = try case_def.run(allocator);
    }

    const timings = try allocator.alloc(u64, options.reps);
    defer allocator.free(timings);

    var ops: usize = 0;
    for (timings, 0..) |*timing, rep_idx| {
        const result = try case_def.run(allocator);
        timing.* = result.elapsed_ns;
        if (rep_idx == 0) ops = result.ops;
    }

    sortAscending(timings);
    return .{
        .name = case_def.name,
        .ops = ops,
        .min_ns = timings[0],
        .median_ns = timings[timings.len / 2],
        .max_ns = timings[timings.len - 1],
    };
}

pub fn printSummary(summary: Summary) void {
    const median_ns_per_op = @as(f64, @floatFromInt(summary.median_ns)) / @as(f64, @floatFromInt(summary.ops));
    const median_ops_per_sec = (@as(f64, 1_000_000_000) * @as(f64, @floatFromInt(summary.ops))) / @as(f64, @floatFromInt(summary.median_ns));
    std.debug.print(
        "{s}: ops={} min={d:.3}ms med={d:.3}ms max={d:.3}ms med_ns/op={d:.1} med_ops/s={d:.0}\n",
        .{
            summary.name,
            summary.ops,
            @as(f64, @floatFromInt(summary.min_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(summary.median_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(summary.max_ns)) / 1_000_000.0,
            median_ns_per_op,
            median_ops_per_sec,
        },
    );
}
