const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // utf8proc C 头的 Zig 绑定（0.17 的 @cImport 已移除——translate-c
    // 是官方替代路径，产物作为普通模块引入）。
    const utf8proc_tc = b.addTranslateC(.{
        .root_source_file = b.path("deps/utf8proc/utf8proc.h"),
        .target = target,
        .optimize = optimize,
    });
    const utf8proc_mod = utf8proc_tc.createModule();

    // Root module with SQLite C source
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addCSourceFiles(.{
        .files = &.{
                "deps/sqlite3/sqlite3.c",
                "deps/utf8proc/utf8proc.c",
            },
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_journal_mode=WAL",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    root_mod.addIncludePath(b.path("deps/sqlite3"));
    // sqlite-vec：静态链接（-DSQLITE_CORE 不走 load_extension API）。
    root_mod.addCSourceFile(.{
        .file = b.path("deps/sqlite_vec/sqlite-vec.c"),
        .flags = &.{"-DSQLITE_CORE"},
    });
    root_mod.addImport("utf8proc", utf8proc_mod);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ziv",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zage agent");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{
        .files = &.{
                "deps/sqlite3/sqlite3.c",
                "deps/utf8proc/utf8proc.c",
            },
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_journal_mode=WAL",
            "-DSQLITE_ENABLE_FTS5",
        },
    });
    test_mod.addIncludePath(b.path("deps/sqlite3"));
    test_mod.addCSourceFile(.{
        .file = b.path("deps/sqlite_vec/sqlite-vec.c"),
        .flags = &.{"-DSQLITE_CORE"},
    });
    test_mod.addImport("utf8proc", utf8proc_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
