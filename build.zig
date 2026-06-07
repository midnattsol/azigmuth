const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const include_stress = b.option(bool, "stress", "Include long-running stress tests in the 'test' step") orelse false;

    const mod = b.addModule("graphz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- check: compile the library ----
    const lib_check = b.addLibrary(.{
        .linkage = .static,
        .name = "graphz",
        .root_module = mod,
    });
    const check_step = b.step("check", "Check that the library compiles");
    check_step.dependOn(&lib_check.step);
    b.getInstallStep().dependOn(&lib_check.step);

    // ---- test: single module provides all test access ----
    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/graph_mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- test helper modules ----
    const publish_mod = b.createModule(.{
        .root_source_file = b.path("tests/internal/helpers/publishing.zig"),
        .target = target,
        .optimize = optimize,
    });
    publish_mod.addImport("graph_mod", graph_mod);

    const graph_helpers_mod = b.createModule(.{
        .root_source_file = b.path("tests/internal/helpers/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    graph_helpers_mod.addImport("graph_mod", graph_mod);

    const neighbors_mod = b.createModule(.{
        .root_source_file = b.path("tests/internal/helpers/neighbors.zig"),
        .target = target,
        .optimize = optimize,
    });
    neighbors_mod.addImport("graph_mod", graph_mod);

    const test_step = b.step("test", "Run the default test suite");
    addTestRunners(b, test_step, target, optimize, graph_mod, mod, publish_mod, graph_helpers_mod, neighbors_mod);
    if (include_stress) {
        addStressFiles(b, test_step, target, optimize, graph_mod, mod, publish_mod, graph_helpers_mod, neighbors_mod);
    }

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("graphz", mod);
    const bench_exe = b.addExecutable(.{
        .name = "graphz-bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run basic performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    const stress_step = b.step("stress", "Run long-running stress tests");
    addStressFiles(b, stress_step, target, optimize, graph_mod, mod, publish_mod, graph_helpers_mod, neighbors_mod);
}

fn addTestModule(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph_mod: *std.Build.Module,
    graphz_mod: *std.Build.Module,
    publish_mod: *std.Build.Module,
    graph_helpers_mod: *std.Build.Module,
    neighbors_mod: *std.Build.Module,
    module_path: []const u8,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "tests", module_path })),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("graphz", graphz_mod);

    if (testNeedsInternals(module_path)) {
        test_mod.addImport("graph_mod", graph_mod);
        test_mod.addImport("publish", publish_mod);
        test_mod.addImport("graph_helpers", graph_helpers_mod);
        test_mod.addImport("neighbors", neighbors_mod);
    }

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn testNeedsInternals(test_path: []const u8) bool {
    return std.mem.startsWith(u8, test_path, "internal/");
}

const test_runners = [_][]const u8{
    "public/api/all.zig",
    "public/algorithms/all.zig",
    "public/builder/all.zig",
    "public/concurrent/all.zig",
    "public/fuzz/all.zig",
    "public/multigraph/all.zig",
    "public/remove_node/all.zig",
    "public/validation/all.zig",
    "internal/api/all.zig",
    "internal/builder/all.zig",
    "internal/concurrent/all.zig",
    "internal/fuzz/all.zig",
    "internal/mutation/all.zig",
    "internal/oom/all.zig",
    "internal/query/all.zig",
    "internal/rcu/all.zig",
    "internal/remove_node/all.zig",
    "internal/repair/all.zig",
    "internal/storage/all.zig",
    "internal/validation/all.zig",
};

fn addRunnerList(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph_mod: *std.Build.Module,
    graphz_mod: *std.Build.Module,
    publish_mod: *std.Build.Module,
    graph_helpers_mod: *std.Build.Module,
    neighbors_mod: *std.Build.Module,
    comptime runner_paths: []const []const u8,
) void {
    inline for (runner_paths) |runner_path| {
        addTestModule(b, test_step, target, optimize, graph_mod, graphz_mod, publish_mod, graph_helpers_mod, neighbors_mod, runner_path);
    }
}

fn addTestRunners(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph_mod: *std.Build.Module,
    graphz_mod: *std.Build.Module,
    publish_mod: *std.Build.Module,
    graph_helpers_mod: *std.Build.Module,
    neighbors_mod: *std.Build.Module,
) void {
    addRunnerList(b, test_step, target, optimize, graph_mod, graphz_mod, publish_mod, graph_helpers_mod, neighbors_mod, &test_runners);
}

fn isStressTest(test_path: []const u8) bool {
    return std.mem.eql(u8, std.Io.Dir.path.basename(test_path), "stress.zig") or
        std.mem.endsWith(u8, test_path, "_stress.zig") or
        std.mem.endsWith(u8, test_path, "_long.zig");
}

fn addStressFiles(
    b: *std.Build,
    stress_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graph_mod: *std.Build.Module,
    graphz_mod: *std.Build.Module,
    publish_mod: *std.Build.Module,
    graph_helpers_mod: *std.Build.Module,
    neighbors_mod: *std.Build.Module,
) void {
    const tests_dir_path = b.pathFromRoot("tests");
    var tests_dir = std.Io.Dir.cwd().openDir(b.graph.io, tests_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open '{s}': {}", .{ tests_dir_path, err });
    };
    defer tests_dir.close(b.graph.io);

    var walker = tests_dir.walk(b.allocator) catch @panic("failed to walk tests directory");
    defer walker.deinit();

    while (true) {
        const entry = walker.next(b.graph.io) catch |err| {
            std.debug.panic("failed to walk '{s}': {}", .{ tests_dir_path, err });
        } orelse break;

        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.basename), ".zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "internal/helpers/")) continue;
        if (std.mem.endsWith(u8, entry.path, "/all.zig")) continue;
        if (!isStressTest(entry.path)) continue;

        addTestModule(b, stress_step, target, optimize, graph_mod, graphz_mod, publish_mod, graph_helpers_mod, neighbors_mod, entry.path);
    }
}
