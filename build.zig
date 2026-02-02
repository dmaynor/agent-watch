const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SQLite C library as a static library
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addCSourceFiles(.{
        .files = &.{"lib/sqlite3.c"},
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_WAL=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_DQS=0",
        },
    });

    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });

    // Main executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(b.path("lib"));
    exe_mod.linkLibrary(sqlite_lib);

    const exe = b.addExecutable(.{
        .name = "agent-watch",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run agent-watch");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(b.path("lib"));
    test_mod.linkLibrary(sqlite_lib);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
