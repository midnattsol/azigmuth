const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // ---- test: run all test-bearing modules ----
    const test_internals_mod = b.createModule(.{
        .root_source_file = b.path("src/test_internals.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all non-stress tests");
    addTestFiles(b, test_step, target, optimize, test_internals_mod);

    const stress_step = b.step("stress", "Run long-running stress tests");
    addTestFile(b, stress_step, target, optimize, test_internals_mod, "stress_rcu.zig");
}

fn addTestFile(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_internals_mod: *std.Build.Module,
    test_path: []const u8,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "tests", test_path })),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("test_internals", test_internals_mod);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn addTestFiles(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_internals_mod: *std.Build.Module,
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
        if (std.mem.eql(u8, entry.basename, "helpers.zig")) continue;
        if (std.mem.eql(u8, entry.basename, "stress_rcu.zig")) continue;

        addTestFile(b, test_step, target, optimize, test_internals_mod, entry.path);
    }
}
