const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SQLite3 static library
    const sqlite_lib = b.addStaticLibrary(.{
        .name = "sqlite3",
        .target = target,
        .optimize = optimize,
    });
    sqlite_lib.addCSourceFile(.{
        .file = b.path("deps/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_journal_mode=WAL",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    sqlite_lib.linkLibC();
    b.installArtifact(sqlite_lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zage",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(sqlite_lib);
    exe.addIncludePath(b.path("deps/sqlite3"));

    // TLS dependencies for HTTPS
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    if (target.result.os.tag == .macos) {
        exe.linkFramework("Security");
        exe.linkFramework("CoreFoundation");
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zage agent");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibrary(sqlite_lib);
    unit_tests.addIncludePath(b.path("deps/sqlite3"));
    unit_tests.linkSystemLibrary("ssl");
    unit_tests.linkSystemLibrary("crypto");
    if (target.result.os.tag == .macos) {
        unit_tests.linkFramework("Security");
        unit_tests.linkFramework("CoreFoundation");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
