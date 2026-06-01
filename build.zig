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
    _ = b.step("check", "Check that the library compiles");
    b.getInstallStep().dependOn(&lib_check.step);

    // ---- test: run all test-bearing modules ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
